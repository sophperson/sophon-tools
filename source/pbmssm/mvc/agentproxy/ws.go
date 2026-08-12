package agentproxy

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"

	"bmssm/logger"
)

// wsPath WebSocket 端点路径（对齐设计文档 §6.3）。
const wsPath = "/agent/ws"

// wsIdleTimeout 连接 30 分钟无任何消息即关闭。
const wsIdleTimeout = 30 * time.Minute

// wsPingInterval 心跳间隔。
const wsPingInterval = 30 * time.Second

// clientFrame 客户端（webchatUI）发来的 WS 帧。
// 与 pico 协议对齐：message.send / session.switch / session.delete / session.cancel / session.new。
type clientFrame struct {
	Type      string         `json:"type"`
	Payload   map[string]any `json:"payload,omitempty"`
	SessionID string         `json:"session_id,omitempty"` // 顶层（兼容 ws.js）
}

// clientMessage 从 message.send payload 提取的内容。
type clientMessage struct {
	Content string `json:"content,omitempty"`
}

// conn 一条 WS 连接：绑定一个 webchat 会话模型，独立流式累积。
//
// 锁约定（避免死锁）：
//   - Hub.mu 保护 conns/byACP 索引；Hub.HandleEvent 持 hub.mu 调 c.enqueue（c.mu）。
//   - 锁顺序：hub.mu 先于 c.mu。close() 不持 c.mu 同时拿 hub.mu（先关 done，再清理）。
//   - c.mu 保护 session/adapter/promptCancel。handleFrame 持 c.mu 处理各 handle*，
//     内部不再重复加锁。
type conn struct {
	ws       *websocket.Conn
	writeMu  sync.Mutex // gorilla 不允许并发写
	send     chan []WSFrame
	done     chan struct{}
	closeOnce sync.Once
	addr     string

	hub    *Hub
	module *Module

	mu           sync.Mutex
	session      *WebchatSession
	adapter      *MessageAdapter
	promptCancel func() error // 进行中的 prompt 取消函数
	roundToken   int64        // 当前回合标记（递增，防旧回合覆盖新回合状态）
}

// Hub 管理全部 WS 连接，并把模块级 ACP 事件路由到对应连接。
//
// 事件路由：Module.dispatchEvent（ACP session/update 解析结果）→ Hub.HandleEvent(ev)。
// 事件带 ACP sessionId；Hub 维护 acpSessionID → conn 索引，精确投递。
type Hub struct {
	module *Module
	key    string // 转发 key（子协议 token.<key> 认证；空 = 放行）

	mu       sync.Mutex
	conns    map[*conn]bool
	byACP    map[string]*conn // acpSessionID -> conn
	started  bool
	srv      *http.Server // WS http.Server（listen 持有，Stop 关闭）
	unlisten func()       // 模块事件监听注销句柄（Start 注册，Stop 调用）
}

// newHub 创建 Hub。key 为转发 key（对齐 llm_proxy_config.forward_key）。
func newHub(module *Module, key string) *Hub {
	return &Hub{
		module: module,
		key:    key,
		conns:  make(map[*conn]bool),
		byACP:  make(map[string]*conn),
	}
}

// Start 启动 Hub：注册模块事件监听、启动独立 WS HTTP server。
func (h *Hub) Start() error {
	h.mu.Lock()
	if h.started {
		h.mu.Unlock()
		return nil
	}
	h.started = true
	h.unlisten = h.module.AddEventListener(h.HandleEvent)
	h.mu.Unlock()

	return h.listen()
}

// listen 启动独立 http.Server 监听 agentproxy.listenIP:port。
// ListenAndServe 是阻塞调用，放在模块 goroutine 里；进程生命周期随模块。
func (h *Hub) listen() error {
	cfg := h.module.cfg
	mux := http.NewServeMux()
	mux.HandleFunc(wsPath, h.serveWS)

	addr := net.JoinHostPort(cfg.ListenIP, strconv.Itoa(cfg.Port))
	srv := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 30 * time.Second,
	}
	logger.Info("agentproxy: ws server listening on %s", addr)
	// 持有引用供 Stop 关闭（加锁写，避免与 Stop 读竞态）。
	h.mu.Lock()
	h.srv = srv
	h.mu.Unlock()

	// 阻塞直到 server 关闭；关闭由 Stop 触发。
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		logger.Error("agentproxy: ws server failed: %v", err)
		h.mu.Lock()
		if h.srv == srv {
			h.srv = nil
		}
		h.mu.Unlock()
		return err
	}
	return nil
}

// Stop 关闭 Hub：注销事件监听、关闭 WS server、关闭全部连接。
func (h *Hub) Stop() {
	h.mu.Lock()
	if !h.started {
		h.mu.Unlock()
		return
	}
	h.started = false
	if h.unlisten != nil {
		h.unlisten()
		h.unlisten = nil
	}
	srv := h.srv
	h.srv = nil
	conns := make([]*conn, 0, len(h.conns))
	for c := range h.conns {
		conns = append(conns, c)
	}
	h.conns = make(map[*conn]bool)
	h.byACP = make(map[string]*conn)
	h.mu.Unlock()

	if srv != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		_ = srv.Shutdown(ctx)
		cancel()
	}
	for _, c := range conns {
		c.close()
	}
}

// HandleEvent 模块事件回调：把 ACP 事件路由到绑定该 ACP 会话的连接。
// 由 Module.dispatchEvent 在模块 goroutine 调用。
func (h *Hub) HandleEvent(ev *ACPSessionUpdate) {
	if ev == nil {
		return
	}
	h.mu.Lock()
	c := h.byACP[ev.SessionID]
	h.mu.Unlock()
	if c == nil {
		// 事件先于绑定或已断线：忽略（多连接各管各的会话）
		return
	}
	c.enqueue(ev)
}

// serveWS WebSocket 升级 + 子协议认证 + 连接生命周期。
func (h *Hub) serveWS(w http.ResponseWriter, r *http.Request) {
	if !h.authSubprotocol(r) {
		logger.Warn("agentproxy: ws auth failed from %s", r.RemoteAddr)
		http.Error(w, "unauthorized", http.StatusForbidden)
		return
	}
	upgrader := websocket.Upgrader{
		ReadBufferSize:  4096,
		WriteBufferSize: 4096,
		CheckOrigin:     func(r *http.Request) bool { return true },
		// 回显客户端请求的子协议（token.<key>），浏览器强制要求服务端回显
		// Sec-WebSocket-Protocol，否则握手失败。认证在 authSubprotocol 已通过，
		// 这里直接把客户端列表透传给 selectSubprotocol 以回显首项。
		Subprotocols: websocket.Subprotocols(r),
	}
	wsConn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	c := &conn{
		ws:      wsConn,
		send:    make(chan []WSFrame, 128),
		done:    make(chan struct{}),
		addr:    r.RemoteAddr,
		hub:     h,
		module:  h.module,
		adapter: NewMessageAdapter(h.module.cfg.Model),
	}
	h.mu.Lock()
	h.conns[c] = true
	h.mu.Unlock()

	logger.Info("agentproxy: ws connected from %s", c.addr)
	go c.writeLoop()
	c.readLoop()
}

// authSubprotocol 校验客户端子协议 token.<key> 与配置转发 key 一致。
// key 未配置（空）时放行（MYS-171 放宽策略对齐：本地回环适配器暴露面可控）。
func (h *Hub) authSubprotocol(r *http.Request) bool {
	if h.key == "" {
		return true
	}
	protos := r.Header.Values("Sec-WebSocket-Protocol")
	for _, p := range protos {
		for _, proto := range strings.Split(p, ",") {
			proto = strings.TrimSpace(proto)
			if strings.HasPrefix(proto, "token.") &&
				strings.TrimPrefix(proto, "token.") == h.key {
				return true
			}
		}
	}
	return false
}

// enqueue 把 ACP 事件映射的帧投递给连接（异步）。
func (c *conn) enqueue(ev *ACPSessionUpdate) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.session == nil {
		return
	}
	frames := c.adapter.OnACPEvent(ev, c.session.ID)
	if len(frames) == 0 {
		return
	}
	select {
	case c.send <- frames:
	case <-c.done:
	default:
		// 发送缓冲满：慢消费者，关闭连接防内存膨胀
		logger.Warn("agentproxy: ws send buffer full, closing %s", c.addr)
		go c.close()
	}
}

// readLoop 主循环：读客户端帧，按类型处理；含心跳与空闲超时。
func (c *conn) readLoop() {
	defer c.close()

	// 心跳：定期 ping
	ticker := time.NewTicker(wsPingInterval)
	defer ticker.Stop()
	go func() {
		for {
			select {
			case <-ticker.C:
				_ = c.writePing()
			case <-c.done:
				return
			}
		}
	}()

	_ = c.ws.SetReadDeadline(time.Now().Add(wsIdleTimeout))
	c.ws.SetPongHandler(func(string) error {
		return c.ws.SetReadDeadline(time.Now().Add(wsIdleTimeout))
	})
	c.ws.SetPingHandler(func(string) error {
		return c.ws.SetReadDeadline(time.Now().Add(wsIdleTimeout))
	})

	for {
		msgType, data, err := c.ws.ReadMessage()
		if err != nil {
			return
		}
		if msgType != websocket.TextMessage {
			continue
		}
		var frame clientFrame
		if err := json.Unmarshal(data, &frame); err != nil {
			logger.Warn("agentproxy: invalid ws frame from %s: %v", c.addr, err)
			continue
		}
		if frame.Type == "" {
			continue
		}
		c.handleFrame(frame)
	}
}

// handleFrame 处理一条客户端帧（持 c.mu）。
func (c *conn) handleFrame(frame clientFrame) {
	c.mu.Lock()
	defer c.mu.Unlock()

	switch frame.Type {
	case "message.send":
		c.handleMessageSendLocked(frame)
	case "session.switch":
		c.handleSessionSwitchLocked(frame)
	case "session.delete":
		c.handleSessionDeleteLocked(frame)
	case "session.list":
		c.handleSessionListLocked()
	case "session.history":
		c.handleSessionHistoryLocked(frame)
	case "session.cancel":
		c.handleSessionCancelLocked()
	case "session.new":
		c.handleSessionNewLocked()
	default:
		logger.Warn("agentproxy: unknown ws frame type %s from %s", frame.Type, c.addr)
	}
}

// handleMessageSendLocked message.send：新建/复用会话 → prompt。
// 前置：持 c.mu。
func (c *conn) handleMessageSendLocked(frame clientFrame) {
	var msg clientMessage
	if b, err := json.Marshal(frame.Payload); err == nil {
		_ = json.Unmarshal(b, &msg)
	}
	content := strings.TrimSpace(msg.Content)
	if content == "" {
		return
	}
	if c.session == nil {
		if err := c.ensureSessionLocked(); err != nil {
			c.enqueueErrorLocked("无法创建会话："+err.Error(), "session_new")
			return
		}
	} else {
		c.adapter.ResetRound()
	}
	if err := c.promptLocked(content); err != nil {
		c.enqueueErrorLocked("发送失败："+err.Error(), "prompt")
	}
}

// ensureSessionLocked 确保连接已绑定 webchat 会话（首次发送时自动创建）。
// 前置：持 c.mu。
func (c *conn) ensureSessionLocked() error {
	if c.session != nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), requestTimeout)
	defer cancel()
	client := c.module.Client()
	if client == nil {
		return fmt.Errorf("reasonix 未就绪")
	}
	s, err := c.module.Sessions().New(ctx, client, "新会话")
	if err != nil {
		return err
	}
	c.bindSessionLocked(s)
	// 绑定 ACP sessionId → 本连接，事件路由生效
	c.hub.mu.Lock()
	c.hub.byACP[s.ACPSessionID] = c
	c.hub.mu.Unlock()
	return nil
}

// bindSessionLocked 绑定会话并通知前端。前置：持 c.mu。
func (c *conn) bindSessionLocked(s *WebchatSession) {
	c.session = s
	select {
	case c.send <- c.adapter.OnSessionCreate(s.ID):
	case <-c.done:
	}
}

// promptLocked 发起 session/prompt。前置：持 c.mu。
// 用一个自增 roundToken 标记当前回合：等待更新流关闭的 goroutine 仅当自己仍是
// 最新回合时清理 promptCancel 并发送 typing.stop（避免旧回合覆盖新回合状态）。
func (c *conn) promptLocked(content string) error {
	// 在途回合：先取消旧的
	if c.promptCancel != nil {
		_ = c.promptCancel()
	}

	s := c.session
	if s == nil {
		return fmt.Errorf("no session")
	}
	updates, cancel, err := c.module.Client().Prompt(context.Background(), s.ACPSessionID, content)
	if err != nil {
		return err
	}
	c.promptCancel = cancel
	c.roundToken++
	token := c.roundToken
	c.adapter.ResetRound()

	// typing.start + 用户消息历史快照
	select {
	case c.send <- c.adapter.OnPromptStart(s.ID):
	case <-c.done:
		return nil
	}
	c.module.Sessions().AppendMessage(s.ID, ChatMessage{Role: "user", Content: content})

	go func(acpID string, tok int64) {
		// 等待更新流关闭（prompt 响应 stopReason 到达）
		for range updates {
		}
		c.mu.Lock()
		if c.roundToken == tok {
			c.promptCancel = nil
			if c.session != nil && c.session.ACPSessionID == acpID {
				select {
				case c.send <- c.adapter.OnPromptEnd(c.session.ID):
				case <-c.done:
				}
			}
		}
		c.mu.Unlock()
	}(s.ACPSessionID, token)
	return nil
}

// handleSessionNewLocked 显式新建会话（前端「+ 新对话」）。前置：持 c.mu。
func (c *conn) handleSessionNewLocked() {
	if err := c.ensureSessionLocked(); err != nil {
		c.enqueueErrorLocked("无法创建会话："+err.Error(), "session_new")
	}
}

// handleSessionSwitchLocked 切换会话。前置：持 c.mu。
// 前端切换会话已重开连接（协议约束：会话绑定连接生命周期），本连接只绑定当前会话。
func (c *conn) handleSessionSwitchLocked(frame clientFrame) {
	sid := frame.SessionID
	if sid == "" {
		if p, ok := frame.Payload["session_id"].(string); ok {
			sid = p
		}
	}
	if sid == "" {
		return
	}
	if _, ok := c.module.Sessions().Get(sid); !ok {
		c.enqueueErrorLocked("会话不存在", "session_not_found")
		return
	}
	c.enqueueErrorLocked("切换会话需重新连接", "switch_reconnect")
}

// handleSessionListLocked session.list：返回服务端全部会话摘要（不含全量消息）。
// 前置：持 c.mu。
func (c *conn) handleSessionListLocked() {
	summaries := make([]map[string]any, 0, 16)
	for _, s := range c.module.Sessions().List() {
		summaries = append(summaries, map[string]any{
			"id":           s.ID,
			"title":        s.Title,
			"acpSessionId": s.ACPSessionID,
			"updatedAt":    s.UpdatedAt,
			"messageCount": len(s.Messages),
		})
	}
	f := WSFrame{Type: "session.list", Payload: map[string]any{"sessions": summaries}}
	select {
	case c.send <- []WSFrame{f}:
	case <-c.done:
	}
}

// handleSessionHistoryLocked session.history：返回指定 webchat 会话的全量消息。
// 前置：持 c.mu。
func (c *conn) handleSessionHistoryLocked(frame clientFrame) {
	sid := frame.SessionID
	if sid == "" {
		if p, ok := frame.Payload["session_id"].(string); ok {
			sid = p
		}
	}
	if sid == "" {
		return
	}
	s, ok := c.module.Sessions().Get(sid)
	if !ok {
		c.enqueueErrorLocked("会话不存在", "session_not_found")
		return
	}
	f := WSFrame{
		Type:      "session.history",
		SessionID: sid,
		Payload:   map[string]any{"session_id": sid, "messages": s.Messages},
	}
	select {
	case c.send <- []WSFrame{f}:
	case <-c.done:
	}
}

// handleSessionDeleteLocked 删除会话。前置：持 c.mu。
// 前端当前不发该帧（switch/delete 为本地操作 + 重连），保留协议兼容：
// 若删除的是本连接绑定的会话，同步解绑事件路由。
func (c *conn) handleSessionDeleteLocked(frame clientFrame) {
	sid := frame.SessionID
	if sid == "" {
		if p, ok := frame.Payload["session_id"].(string); ok {
			sid = p
		}
	}
	if sid == "" {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), requestTimeout)
	defer cancel()
	if err := c.module.Sessions().Delete(ctx, c.module.Client(), sid); err != nil {
		logger.Warn("agentproxy: delete session %s failed: %v", sid, err)
	}
	if c.session != nil && c.session.ID == sid {
		acpID := c.session.ACPSessionID
		c.hub.mu.Lock()
		if c.hub.byACP[acpID] == c {
			delete(c.hub.byACP, acpID)
		}
		c.hub.mu.Unlock()
		c.session = nil
	}
}

// handleSessionCancelLocked 取消当前回合。前置：持 c.mu。
func (c *conn) handleSessionCancelLocked() {
	if c.promptCancel != nil {
		_ = c.promptCancel()
	}
}

// enqueueErrorLocked 发送错误帧。前置：持 c.mu。
func (c *conn) enqueueErrorLocked(message, code string) {
	f := WSFrame{Type: "error", Payload: map[string]any{"message": message, "code": code}}
	if c.session != nil {
		f.SessionID = c.session.ID
	}
	select {
	case c.send <- []WSFrame{f}:
	case <-c.done:
	}
}

// writeLoop 串行写下行帧（gorilla 不允许并发写）。
func (c *conn) writeLoop() {
	for {
		select {
		case frames := <-c.send:
			for _, f := range frames {
				if err := c.writeJSON(f); err != nil {
					c.close()
					return
				}
			}
		case <-c.done:
			return
		}
	}
}

func (c *conn) writeJSON(v any) error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	_ = c.ws.SetWriteDeadline(time.Now().Add(10 * time.Second))
	return c.ws.WriteJSON(v)
}

func (c *conn) writePing() error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	_ = c.ws.SetWriteDeadline(time.Now().Add(10 * time.Second))
	return c.ws.WriteMessage(websocket.PingMessage, nil)
}

// close 关闭连接并清理绑定。
// 锁顺序：先 close(done)（触发 writeLoop/心跳 goroutine 退出），
// 再 c.mu 清理本地状态（不碰 hub），最后 hub.mu 解绑——避免 c.mu→hub.mu 与
// HandleEvent 的 hub.mu→c.mu 成环。
func (c *conn) close() {
	c.closeOnce.Do(func() {
		close(c.done)

		c.mu.Lock()
		s := c.session
		if c.promptCancel != nil {
			_ = c.promptCancel()
			c.promptCancel = nil
		}
		c.session = nil
		c.mu.Unlock()

		c.hub.mu.Lock()
		if s != nil && c.hub.byACP[s.ACPSessionID] == c {
			delete(c.hub.byACP, s.ACPSessionID)
		}
		delete(c.hub.conns, c)
		c.hub.mu.Unlock()

		_ = c.ws.Close()
		logger.Info("agentproxy: ws closed from %s", c.addr)
	})
}
