package agentproxy

import (
	"encoding/json"
	"strings"
	"time"

	"bmssm/logger"
)

// PermissionRequestParams ACP agent 发起的 session/request_permission 请求参数。
// 结构对齐 reasonix PermissionRequestParams（internal/acp/protocol.go）。
type PermissionRequestParams struct {
	SessionID string             `json:"sessionId"`
	ToolCall  PermissionToolCall `json:"toolCall"`
	Options   []PermissionOption `json:"options"`
}

// PermissionToolCall 待审批的工具调用描述。
type PermissionToolCall struct {
	ToolCallID string          `json:"toolCallId,omitempty"`
	Title      string          `json:"title,omitempty"`
	Kind       string          `json:"kind,omitempty"`
	Status     string          `json:"status,omitempty"`
	RawInput   json.RawMessage `json:"rawInput,omitempty"`
}

// PermissionOption 审批选项之一（host 需回显其 optionId 以「selected」放行）。
type PermissionOption struct {
	OptionID string `json:"optionId"`
	Name     string `json:"name"`
	Kind     string `json:"kind"`
}

// pendingPermission 一次待审批的工具权限请求。
// reqID 用于最终应答 ACP（同一会话可能同时有多个待审批，按键 reqID 区分）；
// sessionID/webchatID 用于定位前端会话；webchatID 供前端定位会话展示。
type pendingPermission struct {
	reqID     int64
	sessionID string // ACP sessionId（reasonix 侧）
	webchatID string // webchat 会话 id（前端定位）
	toolCall  PermissionToolCall
	options   []PermissionOption // ask 决策的可选项（回传校验用）
	timer     *time.Timer
}

// ResultFrameClient 组装 permission.request WS 帧负载（protobuf 无关，纯 map）。
func permissionRequestFrame(webchatID string, reqID int64, tc PermissionToolCall, options []PermissionOption) WSFrame {
	return WSFrame{
		Type:      "permission.request",
		SessionID: webchatID,
		Payload: map[string]any{
			"session_id": webchatID,
			"request_id": reqID,
			"tool_call":  tc,
			"options":    options,
			"is_ask":     isAskDecision(options),
		},
	}
}

// permissionRespondedFrame 组装审批已回执的 WS 帧（前端据此关闭/更新审批卡片）。
func permissionRespondedFrame(webchatID string, reqID int64, allow bool) WSFrame {
	return WSFrame{
		Type:      "permission.responded",
		SessionID: webchatID,
		Payload: map[string]any{
			"session_id": webchatID,
			"request_id": reqID,
			"allow":      allow,
		},
	}
}

// dispatchPermissionRequest 处理 agent 发起的 session/request_permission：
// 记录待审批并投递 WS permission.request 帧到绑定该会话的连接。
// reqID 非 nil（调用方已判断该请求带 id）。
func (m *Module) dispatchPermissionRequest(reqID int64, params json.RawMessage) {
	var req PermissionRequestParams
	if err := json.Unmarshal(params, &req); err != nil {
		logger.Info("agentproxy: invalid request_permission params: %v", err)
		return
	}
	if req.SessionID == "" {
		logger.Info("agentproxy: request_permission without sessionId, ignore")
		return
	}
	// 定位 webchat 会话 id（前端以它定位会话）
	webchatID := req.SessionID
	if sess, ok := m.sessions.GetByACP(req.SessionID); ok {
		webchatID = sess.ID
	}

	// 记录待审批（带超时自动拒绝，避免无人响应时永久挂起）
	pp := &pendingPermission{
		reqID:     reqID,
		sessionID: req.SessionID,
		webchatID: webchatID,
		toolCall:  req.ToolCall,
		options:   req.Options,
	}
	timeout := m.permissionTimeout()
	pp.timer = time.AfterFunc(timeout, func() {
		m.RespondPermissionOption(reqID, false, "")
	})

	m.mu.Lock()
	if m.perms == nil {
		m.perms = make(map[int64]*pendingPermission)
	}
	// 以 reqID 为键：同一会话可能同时有多个待审批（模型可并发发 request_permission），
	// 避免后者覆盖前者导致其 reqID 无人应答而悬挂。
	m.perms[reqID] = pp
	m.mu.Unlock()

	logger.Info("agentproxy: permission request session=%s tool=%s reqID=%d", req.SessionID, req.ToolCall.Title, reqID)
	if m.hub != nil {
		m.hub.BroadcastSession(req.SessionID, permissionRequestFrame(webchatID, reqID, req.ToolCall, req.Options))
	}
}

// RespondPermission 兼容旧签名：allow=true → selected/allow_once；false → cancelled。
func (m *Module) RespondPermission(reqID int64, allow bool) {
	m.RespondPermissionOption(reqID, allow, "")
}

// RespondPermissionOption 按选项应答。allow=true 且 optionID 非空 → selected+该 optionId；
// 否则 allow=true → selected+allow_once；false → cancelled。
func (m *Module) RespondPermissionOption(reqID int64, allow bool, optionID string) {
	m.mu.Lock()
	pp := m.perms[reqID]
	if pp == nil {
		m.mu.Unlock()
		return
	}
	delete(m.perms, reqID)
	m.mu.Unlock()

	if pp.timer != nil {
		pp.timer.Stop()
	}

	client := m.Client()
	if client == nil {
		logger.Warn("agentproxy: respond permission but client not ready (reqID %d)", reqID)
		return
	}
	if err := client.ResolvePermissionOption(reqID, allow, optionID); err != nil {
		logger.Warn("agentproxy: respond permission %d failed: %v", pp.reqID, err)
	}
	if m.hub != nil {
		m.hub.BroadcastSession(pp.sessionID, permissionRespondedFrame(pp.webchatID, pp.reqID, allow))
	}
	logger.Info("agentproxy: permission %d resolved allow=%v option=%q", pp.reqID, allow, optionID)
}

// denyPermissionsForSession 在会话解绑/断线等场景净空其待审批请求（自动拒绝）。
// denyPermissionsForSession 在会话解绑/断线/新一轮等场景净空其全部待审批请求（自动拒绝）。
func (m *Module) denyPermissionsForSession(sessionID string) {
	m.mu.Lock()
	var toDeny []*pendingPermission
	for id, pp := range m.perms {
		if pp.sessionID == sessionID {
			toDeny = append(toDeny, pp)
			delete(m.perms, id)
			if pp.timer != nil {
				pp.timer.Stop()
			}
		}
	}
	m.mu.Unlock()
	if len(toDeny) == 0 {
		return
	}
	client := m.Client()
	if client == nil {
		return
	}
	for _, pp := range toDeny {
		_ = client.ResolvePermission(pp.reqID, false)
	}
}

// clearPendingPermissions 在 reasonix 进程重启/模块关闭时取消全部待审批（避免
// 悬挂的 AfterFunc 在进程重建后仍去应答已失效的 stream；直接丢弃）。
func (m *Module) clearPendingPermissions() {
	m.mu.Lock()
	for _, pp := range m.perms {
		if pp.timer != nil {
			pp.timer.Stop()
		}
	}
	m.perms = make(map[int64]*pendingPermission)
	m.mu.Unlock()
}

// permissionTimeout 返回待审批超时（默认 60s；0 表示不超时）。
func (m *Module) permissionTimeout() time.Duration {
	m.mu.Lock()
	cfg := m.cfg
	m.mu.Unlock()
	if cfg.PermissionTimeout == "" {
		return 60 * time.Second
	}
	d, err := time.ParseDuration(cfg.PermissionTimeout)
	if err != nil || d <= 0 {
		return 60 * time.Second
	}
	return d
}

// genericApprovalTokens 通用审批态标签（含取消）。isAskDecision 据此区分：
// options 若出现任意非通用审批态标签的首 token，视为 ask 用户决策（真实候选）；
// 否则视为普通命令审批（允许/拒绝）。
var genericApprovalTokens = map[string]struct{}{
	"允许": {}, "拒绝": {}, "取消": {}, "确定": {},
	"allow": {}, "deny": {}, "cancel": {}, "yes": {}, "no": {},
	"reject": {}, "approve": {}, // 英文命令审批常见选项（如 write_file 的 Allow/Reject）
	"ok": {},
}

// firstToken 取 option.name 首段（按 `/`、`-`、空格、`：`、`:` 切）。
func firstToken(name string) string {
	for _, sep := range []rune{'/', '-', ' ', '：', ':'} {
		if i := indexRune(name, sep); i >= 0 {
			return lowerTrim(name[:i])
		}
	}
	return lowerTrim(name)
}

func indexRune(s string, r rune) int {
	for i, c := range s {
		if c == r {
			return i
		}
	}
	return -1
}

func lowerTrim(s string) string {
	s = strings.TrimSpace(s)
	return strings.ToLower(s)
}

// isAskDecision 判定 request_permission 是否为「ask 用户决策」。
// 规则：options 中存在某 option 的首 token 不属于通用审批态集合 => 用户决策 ask。
// 覆盖真机抓帧：命令审批首 token=允许/拒绝 → false；ask 决策首 token=先查a/先查b → true。
func isAskDecision(options []PermissionOption) bool {
	if len(options) == 0 {
		return false
	}
	for _, o := range options {
		if _, ok := genericApprovalTokens[firstToken(o.Name)]; !ok {
			return true
		}
	}
	return false
}
