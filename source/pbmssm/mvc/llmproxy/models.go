package llmproxy

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// fetchModels 从上游 openai 兼容接口拉取模型列表（GET /models）。
func fetchModels(prov ProviderConfig) ([]ModelInfo, error) {
	if prov.ApiBase == "" {
		return nil, fmt.Errorf("api_base empty")
	}
	upstreamURL := strings.TrimRight(prov.ApiBase, "/") + "/models"
	req, err := http.NewRequest(http.MethodGet, upstreamURL, nil)
	if err != nil {
		return nil, err
	}
	if prov.ApiKey != "" {
		req.Header.Set("Authorization", "Bearer "+prov.ApiKey)
	}
	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("upstream %s returned %d: %s", upstreamURL, resp.StatusCode, truncate(string(body), 200))
	}
	var out struct {
		Data []ModelInfo `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	return out.Data, nil
}

// truncate 截断过长的错误信息。
func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}
