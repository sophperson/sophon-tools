package llmproxy

import (
	"github.com/jinzhu/gorm"

	"bmssm/logger"
)

// Migrate 对 llm_proxy_config 表做显式迁移：gorm v1 AutoMigrate 对 sqlite
// 已有表加新列不可靠，这里用 ALTER TABLE 补齐旧版本缺的列。
// 在 bmssm 启动（InitBase）时调用一次。
func Migrate(db *gorm.DB) {
	if db == nil {
		return
	}
	if !db.HasTable(&Config{}) {
		// 表不存在由 AutoMigrate 创建（含全部新列）
		return
	}
	cols := []struct {
		name string
		typ  string
	}{
		{"llm_api_base", "text"},
		{"llm_api_key", "text"},
		{"llm_model", "text"},
		{"llm_enabled", "bool"},
		{"vlm_api_base", "text"},
		{"vlm_api_key", "text"},
		{"vlm_model", "text"},
		{"vlm_enabled", "bool"},
		{"forward_key", "text"},
		{"forward_key_written", "bool"},
	}
	for _, c := range cols {
		if db.Dialect().HasColumn("llm_proxy_config", c.name) {
			continue
		}
		sql := "ALTER TABLE llm_proxy_config ADD COLUMN " + c.name + " " + c.typ
		if err := db.Exec(sql).Error; err != nil {
			logger.Warn("llmproxy migrate add %s failed: %v", c.name, err)
		} else {
			logger.Info("llmproxy migrate: added column %s", c.name)
		}
	}
	// 旧版本字段迁移到新结构（旧 api_base/api_key/target_model/enabled → llm_*）
	db.Exec("UPDATE llm_proxy_config SET llm_api_base = api_base WHERE llm_api_base IS NULL AND api_base IS NOT NULL")
	db.Exec("UPDATE llm_proxy_config SET llm_api_key = api_key WHERE llm_api_key IS NULL AND api_key IS NOT NULL")
	db.Exec("UPDATE llm_proxy_config SET llm_model = target_model WHERE llm_model IS NULL AND target_model IS NOT NULL")
	db.Exec("UPDATE llm_proxy_config SET llm_enabled = enabled WHERE llm_enabled IS NULL")
}
