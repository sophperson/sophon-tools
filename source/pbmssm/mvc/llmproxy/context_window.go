package llmproxy

import (
	"sync"

	"bmssm/logger"
)

// ContextWindowApplier 根据 LLM 上游 API Base 调整 Reasonix 的上下文预算。
// llmproxy 只声明回调，不同 llmproxy 引入 agentproxy（避免包循环）；
// agentproxy 在启动时通过 RegisterContextWindowApplier 注册实现。
type ContextWindowApplier func(apiBase string) error

var (
	applierMu sync.RWMutex
	applier   ContextWindowApplier
)

// RegisterContextWindowApplier 注册上下文预算回调（每保存一次 LLM 配置触发一次）。
func RegisterContextWindowApplier(fn ContextWindowApplier) {
	applierMu.Lock()
	defer applierMu.Unlock()
	applier = fn
}

// ApplyContextWindow 保存 LLM 配置后调用：按上游 apiBase 通知实现方重写上下文。
// 未注册或执行失败都不阻断保存流程（仅告警）。
func ApplyContextWindow(apiBase string) {
	applierMu.RLock()
	fn := applier
	applierMu.RUnlock()
	if fn == nil {
		return
	}
	if err := fn(apiBase); err != nil {
		logger.Warn("llm proxy: apply context window failed: %v", err)
	}
}