package agentproxy

import (
	"encoding/json"
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
// reasonix 已移除模型侧 ask 工具（MYS-212）：本端收到的 permission.request 只含
// 命令审批（Allow/allow_always/Reject），不再有真实候选选项的选择题 ask，故不再
// 下发 is_ask 字段——自动审批可直接全部允许，无需启发式区分。
func permissionRequestFrame(webchatID string, reqID int64, tc PermissionToolCall, options []PermissionOption) WSFrame {
	return WSFrame{
		Type:      "permission.request",
		SessionID: webchatID,
		Payload: map[string]any{
			"session_id": webchatID,
			"request_id": reqID,
			"tool_call":  tc,
			"options":    options,
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
