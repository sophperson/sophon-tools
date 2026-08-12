package llmproxy

import (
	"crypto/rand"
	"encoding/base64"
	"errors"
	"strings"
	"time"

	"github.com/jinzhu/gorm"
)

// Service 封装 LLM 转发配置的读写（不依赖 gin）。
type Service struct {
	db *gorm.DB
}

// NewService 创建 Service。
func NewService(db *gorm.DB) *Service { return &Service{db: db} }

// LoadConfig 读取已存配置；无记录返回默认配置（并确保生成转发 key）。
// DB 为空时也返回默认配置（bmssm DB 初始化失败的非致命降级路径）。
func (s *Service) LoadConfig() Config {
	def := DefaultConfig()
	if s == nil || s.db == nil {
		def.ForwardKey = s.ensureForwardKey(def)
		return def
	}
	var c Config
	if err := s.db.First(&c, 1).Error; err != nil {
		// 无记录：写入默认配置（含新生成的转发 key）
		c = def
		c.ID = 1
		c.ForwardKey = GenerateForwardKey()
		c.UpdatedAt = time.Now()
		if err := s.db.Save(&c).Error; err == nil {
			return c
		}
		return c
	}
	c.normalizeDefaults()
	if c.ForwardKey == "" {
		c.ForwardKey = GenerateForwardKey()
		_ = s.db.Model(&Config{}).Where("id = ?", 1).Update("forward_key", c.ForwardKey).Error
	}
	return c
}

// ensureForwardKey 保证配置带转发 key；有则复用，无则生成并落库。
func (s *Service) ensureForwardKey(c Config) string {
	if c.ForwardKey != "" {
		return c.ForwardKey
	}
	key := GenerateForwardKey()
	if s != nil && s.db != nil {
		// 尝试落库（失败不阻断，内存态仍有效）
		_ = s.db.Model(&Config{}).Where("id = ?", 1).Update("forward_key", key).Error
	}
	return key
}

// GenerateForwardKey 生成随机转发 key（32 字节 base64url，无填充）。
func GenerateForwardKey() string {
	buf := make([]byte, 32)
	_, _ = rand.Read(buf)
	return base64.RawURLEncoding.EncodeToString(buf)
}

// SaveConfig 保存配置（upsert 到 ID=1）。
// 各 key 为空时保留原值（前端脱敏不回传）。
func (s *Service) SaveConfig(req SaveRequest) (Config, error) {
	cur := s.LoadConfig()
	enabled := func(v *bool, def bool) bool {
		if v != nil {
			return *v
		}
		return def
	}
	c := Config{
		ID:          1,
		LLMApiBase:  nonEmpty(req.LLMApiBase, cur.LLMApiBase, "https://www.sophnet.com/api/open-apis/v1"),
		LLMApiKey:   nonEmpty(req.LLMApiKey, cur.LLMApiKey, ""),
		LLMModel:    nonEmpty(req.LLMModel, cur.LLMModel, "sophnet-deepseek"),
		LLMEnabled:  enabled(req.LLMEnabled, cur.LLMEnabled),
		LLMOverride: enabled(req.LLMOverride, cur.LLMOverride),
		VLMApiBase:  nonEmpty(req.VLMApiBase, cur.VLMApiBase, "https://www.sophnet.com/api/open-apis/v1"),
		VLMApiKey:   nonEmpty(req.VLMApiKey, cur.VLMApiKey, ""),
		VLMModel:    nonEmpty(req.VLMModel, cur.VLMModel, "sophnet-vl-flash"),
		VLMEnabled:  enabled(req.VLMEnabled, cur.VLMEnabled),
		VLMOverride: enabled(req.VLMOverride, cur.VLMOverride),
		ForwardKey:  cur.ForwardKey,
		UpdatedAt:   time.Now(),
	}
	if s == nil || s.db == nil {
		return c, errors.New("database unavailable")
	}
	if err := s.db.Save(&c).Error; err != nil {
		return Config{}, err
	}
	return c, nil
}

// ResetForwardKey 重置转发 key（生成新的并落库）。
func (s *Service) ResetForwardKey() (string, error) {
	if s == nil || s.db == nil {
		return "", errors.New("database unavailable")
	}
	key := GenerateForwardKey()
	if err := s.db.Model(&Config{}).Where("id = ?", 1).Update("forward_key", key).Error; err != nil {
		return "", err
	}
	return key, nil
}

// SetForwardKeyWritten 标记转发 key 已写入本地 picoclaw。
func (s *Service) SetForwardKeyWritten() {
	if s != nil && s.db != nil {
		_ = s.db.Model(&Config{}).Where("id = ?", 1).Update("forward_key_written", true).Error
	}
}

// ForwardKeyWritten 查询转发 key 是否已写入本地 picoclaw。
func (s *Service) ForwardKeyWritten() bool {
	if s == nil || s.db == nil {
		return false
	}
	var written bool
	_ = s.db.Model(&Config{}).Where("id = ?", 1).Pluck("forward_key_written", &written).Error
	return written
}

// ToResponse 构造响应（脱敏 key；ForwardKey 明文）。
func (c Config) ToResponse(written bool) ConfigResponse {
	return ConfigResponse{
		LLMApiBase:      c.LLMApiBase,
		LLMModel:        c.LLMModel,
		LLMEnabled:      c.LLMEnabled,
		LLMOverride:     c.LLMOverride,
		LLMHasKey:       c.LLMApiKey != "",
		VLMApiBase:      c.VLMApiBase,
		VLMModel:        c.VLMModel,
		VLMEnabled:      c.VLMEnabled,
		VLMOverride:     c.VLMOverride,
		VLMHasKey:       c.VLMApiKey != "",
		ForwardKey:      c.ForwardKey,
		ForwardKeyReady: written,
		UpdatedAt:       c.UpdatedAt,
	}
}

// normalizeDefaults 补齐默认值（兼容旧表结构缺字段）。
func (c *Config) normalizeDefaults() {
	def := DefaultConfig()
	if strings.TrimSpace(c.LLMApiBase) == "" {
		c.LLMApiBase = def.LLMApiBase
	}
	if strings.TrimSpace(c.LLMModel) == "" {
		c.LLMModel = def.LLMModel
	}
	if strings.TrimSpace(c.VLMApiBase) == "" {
		c.VLMApiBase = def.VLMApiBase
	}
	if strings.TrimSpace(c.VLMModel) == "" {
		c.VLMModel = def.VLMModel
	}
}

// nonEmpty 取第一个非空值；全部为空时回退 fallback。
func nonEmpty(vals ...string) string {
	for _, v := range vals {
		if strings.TrimSpace(v) != "" {
			return strings.TrimSpace(v)
		}
	}
	return ""
}
