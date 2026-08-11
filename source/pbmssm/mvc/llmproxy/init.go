package llmproxy

import "bmssm/database"

func init() {
	database.RegisterModel(&Config{})
}