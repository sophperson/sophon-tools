package agentproxy

import (
	"strconv"
	"strings"
	"time"

	"bmssm/config"
)

// LoadConfig 读取 agentproxy 配置：sqlite 优先，viper 兜底。
// 本任务（S2）暂不落库：直接读 viper（bmssm.yaml agentproxy 段）+ 默认值。
// S3 起由 controller.go 提供 REST 保存（sqlite 单例），本函数保持兼容。
func LoadConfig() Config {
	conf := &config.Conf
	conf.RLock()
	defer conf.RUnlock()
	v := conf.GetViper()

	return Config{
		Enabled:    v.GetBool("agentproxy.enabled"),
		ListenIP:   v.GetString("agentproxy.listenIP"),
		Port:       v.GetInt("agentproxy.port"),
		BinaryPath: v.GetString("agentproxy.binaryPath"),
		WorkDir:    v.GetString("agentproxy.workDir"),
		Model:      v.GetString("agentproxy.model"),
		RestartBackoffMax: v.GetString("agentproxy.restartBackoffMax"),
	}
}

// DefaultConfig 返回默认配置。
func DefaultConfig() Config {
	return Config{
		Enabled:    true,
		ListenIP:   "127.0.0.1",
		Port:       DefaultPort,
		BinaryPath: DefaultBinary,
		WorkDir:    DefaultWorkDir,
	}
}

// Normalize 补齐默认值。
func (c *Config) Normalize() {
	if c.ListenIP == "" {
		c.ListenIP = "127.0.0.1"
	}
	if c.Port == 0 {
		c.Port = DefaultPort
	}
	if strings.TrimSpace(c.BinaryPath) == "" {
		c.BinaryPath = DefaultBinary
	}
	if strings.TrimSpace(c.WorkDir) == "" {
		c.WorkDir = DefaultWorkDir
	}
}

// BackoffMax 解析重启退避上限（人类可读时长，失败用默认）。
func (c *Config) BackoffMax() time.Duration {
	if c.RestartBackoffMax == "" {
		return DefaultBackoffMax
	}
	if d, err := time.ParseDuration(c.RestartBackoffMax); err == nil {
		return d
	}
	return DefaultBackoffMax
}

// Addr 返回 WS 监听地址（S3 使用）。
func (c *Config) Addr() string {
	return c.ListenIP + ":" + strconv.Itoa(c.Port)
}
