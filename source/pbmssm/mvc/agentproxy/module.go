package agentproxy

import (
	"context"
	"encoding/json"
	"os"
	"sync"
	"time"

	"github.com/jinzhu/gorm"

	"bmssm/logger"
)

// Module 是 agentproxy 适配器的顶层装配：进程管理 + ACP 客户端 + 会话管理。
// S2 交付核心链路：reasonix 进程自愈、initialize 握手、会话 new/prompt/cancel/close、
// 流式 update 分发（事件回调给协议层，S3 转 WS 帧）。
type Module struct {
	cfg      Config
	db       *gorm.DB
	pm       *ProcessManager
	client   *Client
	sessions *SessionManager

	mu      sync.Mutex
	started bool
	eventFn func(*ACPSessionUpdate) // S3 协议层注入：ACP 事件 → WS 帧

	stopOnce sync.Once
}

// 全局单例（bmssm 生命周期内唯一；main.go shutdown 时 Shutdown()）。
var (
	globalMu  sync.Mutex
	globalMod *Module
)

// Start 启动 agentproxy 模块（初始化接线调用）。
func Start(cfg Config, db *gorm.DB) *Module {
	globalMu.Lock()
	defer globalMu.Unlock()
	if globalMod != nil {
		return globalMod
	}
	globalMod = NewModule(cfg, db, nil)
	if err := globalMod.Start(); err != nil {
		logger.Error("agentproxy: start failed: %v", err)
	}
	return globalMod
}

// Shutdown 优雅关闭全局模块（main.go shutdown 时调用）。
func Shutdown() {
	globalMu.Lock()
	m := globalMod
	globalMod = nil
	globalMu.Unlock()
	if m != nil {
		m.Shutdown()
	}
}

// NewModule 创建装配模块。eventFn 为流式事件回调（可为 nil，S3 注入）。
func NewModule(cfg Config, db *gorm.DB, eventFn func(*ACPSessionUpdate)) *Module {
	cfg.Normalize()
	m := &Module{
		cfg:     cfg,
		db:      db,
		eventFn: eventFn,
	}
	m.sessions = NewSessionManager(db, cfg.WorkDir)
	m.pm = NewProcessManager(cfg, m.onProcessReady)
	return m
}

// Start 启动适配器：迁移（已由初始化调用）、加载会话、启动进程。
// 幂等。
func (m *Module) Start() error {
	m.mu.Lock()
	if m.started {
		m.mu.Unlock()
		return nil
	}
	m.started = true
	m.mu.Unlock()

	if m.cfg.WorkDir != "" {
		_ = ensureWorkDir(m.cfg.WorkDir)
	}
	m.sessions.LoadAll()
	if !m.cfg.Enabled {
		logger.Info("agentproxy: disabled, reasonix acp not started")
		return nil
	}
	return m.pm.Start()
}

// Shutdown 优雅关闭：先关闭所有活动会话，再停止进程与客户端。
func (m *Module) Shutdown() {
	m.stopOnce.Do(func() {
		m.mu.Lock()
		client := m.client
		m.mu.Unlock()
		if client != nil {
			// 关闭活动会话（超时 3s 兜底）
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			m.sessions.CloseAll(ctx, client)
			cancel()
		}
		if m.pm != nil {
			m.pm.GracefulStop()
		}
		if client != nil {
			client.Close()
		}
	})
}

// Client 返回当前 ACP 客户端（未初始化则 nil）。
func (m *Module) Client() *Client {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.client
}

// Sessions 返回会话管理器。
func (m *Module) Sessions() *SessionManager {
	return m.sessions
}

// Process 返回进程管理器（健康检查/状态查询）。
func (m *Module) Process() *ProcessManager {
	return m.pm
}

// SetEventFn 注入流式事件回调（S3 协议层调用，连接级）。
func (m *Module) SetEventFn(fn func(*ACPSessionUpdate)) {
	m.mu.Lock()
	m.eventFn = fn
	m.mu.Unlock()
}

// onProcessReady 每次 reasonix 进程成功启动后被回调：
// 重建 client → initialize 握手 → 恢复会话。
func (m *Module) onProcessReady() {
	m.mu.Lock()
	old := m.client
	m.mu.Unlock()
	if old != nil {
		old.Close()
	}

	m.mu.Lock()
	m.client = NewClient(m.pm, m.dispatchEvent, m.dispatchNotify)
	m.mu.Unlock()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	initResult, err := m.client.Initialize(ctx)
	if err != nil {
		logger.Error("agentproxy: initialize failed: %v", err)
		m.pm.MarkInitFailed()
		// stderr 提示 reasonix setup
		if s := m.pm.StderrSnapshot(512); s != "" {
			logger.Info("agentproxy: reasonix stderr: %s", s)
		}
		return
	}
	m.pm.MarkInitOK()
	logger.Info("agentproxy: initialize ok protocolVersion=%d", initResult.ProtocolVersion)

	// 恢复 active 会话
	if m.sessions != nil {
		m.sessions.Restore(ctx, m.client)
	}
}

// dispatchEvent 收到 session/update 解析结果，转事件回调。
func (m *Module) dispatchEvent(ev *ACPSessionUpdate) {
	if ev == nil {
		return
	}
	m.mu.Lock()
	fn := m.eventFn
	m.mu.Unlock()
	if fn != nil {
		fn(ev)
	}
}

// dispatchNotify 收到未识别下行通知/agent 请求。
// 当前仅记日志；S3 协议层可扩展（permission.request 等）。
func (m *Module) dispatchNotify(method string, params json.RawMessage) {
	logger.Info("agentproxy: downlink notify %s", method)
}

// Status 返回适配器状态（健康检查/管理接口用）。
func (m *Module) Status() map[string]any {
	m.mu.Lock()
	clientReady := m.client != nil
	m.mu.Unlock()
	return map[string]any{
		"enabled":      m.cfg.Enabled,
		"process":      string(m.pm.State()),
		"alive":        m.pm.Alive(),
		"healthy":      m.pm.Healthy(),
		"clientReady":  clientReady,
		"pid":          m.pm.Pid(),
		"sessionCount": len(m.sessions.List()),
		"stderr":       m.pm.StderrSnapshot(512),
	}
}

// ensureWorkDir 确保工作区目录存在（reasonix 会话 cwd）。
func ensureWorkDir(dir string) error {
	if dir == "" {
		return nil
	}
	if st, err := os.Stat(dir); err == nil && st.IsDir() {
		return nil
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		logger.Warn("agentproxy: create workdir %s failed: %v", dir, err)
		return err
	}
	return nil
}
