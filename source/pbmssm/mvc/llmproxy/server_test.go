package llmproxy

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"bmssm/database"

	"github.com/jinzhu/gorm"
	_ "github.com/jinzhu/gorm/dialects/sqlite"
)

// setupTestDB 建临时 sqlite，注册模型并迁移。
func setupTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open("sqlite3", ":memory:")
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	if err := db.AutoMigrate(&Config{}).Error; err != nil {
		t.Fatalf("migrate: %v", err)
	}
	database.SetDB(db)
	return db
}

// setActive 注入当前配置到全局（避免真实 server 端口）。
func setActive(cfg Config) {
	mu.Lock()
	activeCfg = cfg
	mu.Unlock()
}

func TestServiceLLMAndVLMConfig(t *testing.T) {
	db := setupTestDB(t)
	defer db.Close()
	svc := NewService(db)

	// 默认配置
	cfg := svc.LoadConfig()
	if cfg.LLMApiBase != "https://www.sophnet.com/api/open-apis/v1" {
		t.Errorf("default llmApiBase = %q", cfg.LLMApiBase)
	}
	if cfg.LLMModel != "sophnet-deepseek" {
		t.Errorf("default llmModel = %q", cfg.LLMModel)
	}
	if cfg.VLMModel != "sophnet-vl-flash" {
		t.Errorf("default vlmModel = %q", cfg.VLMModel)
	}
	if cfg.ForwardKey == "" {
		t.Error("forward key should be auto-generated")
	}

	// 保存 LLM/VLM 两套
	llmOn, vlmOn := true, true
	saved, err := svc.SaveConfig(SaveRequest{
		LLMApiBase: "https://llm.example.com/v1",
		LLMApiKey:  "llm-key",
		LLMModel:   "llm-model",
		LLMEnabled: &llmOn,
		VLMApiBase: "https://vlm.example.com/v1",
		VLMApiKey:  "vlm-key",
		VLMModel:   "vlm-model",
		VLMEnabled: &vlmOn,
	})
	if err != nil {
		t.Fatalf("save: %v", err)
	}
	if saved.LLMApiKey != "llm-key" || saved.VLMApiKey != "vlm-key" {
		t.Errorf("saved keys = %q/%q", saved.LLMApiKey, saved.VLMApiKey)
	}
	fk := saved.ForwardKey

	// 读取回填
	got := svc.LoadConfig()
	if got.LLMModel != "llm-model" || got.VLMModel != "vlm-model" {
		t.Errorf("loaded = %+v", got)
	}
	if got.ForwardKey != fk {
		t.Error("forward key should persist across loads")
	}

	// key 空串 → 保留原值
	saved2, _ := svc.SaveConfig(SaveRequest{LLMApiKey: "", VLMApiKey: ""})
	if saved2.LLMApiKey != "llm-key" || saved2.VLMApiKey != "vlm-key" {
		t.Errorf("empty keys should keep old: %q/%q", saved2.LLMApiKey, saved2.VLMApiKey)
	}
}

func TestServiceLoadWhenDBEmpty(t *testing.T) {
	database.SetDB(nil)
	svc := NewService(nil)
	cfg := svc.LoadConfig()
	if cfg.LLMModel == "" || cfg.VLMModel == "" {
		t.Error("nil db should return defaults")
	}
}

func TestForwardKeyAuth(t *testing.T) {
	db := setupTestDB(t)
	defer db.Close()
	svc := NewService(db)
	cfg, _ := svc.SaveConfig(SaveRequest{
		LLMApiBase: "http://127.0.0.1:1/v1", LLMApiKey: "k", LLMModel: "m",
		VLMApiBase: "http://127.0.0.1:1/v1", VLMApiKey: "k", VLMModel: "m",
	})
	// 强制设一个已知转发 key
	cfg.ForwardKey = "test-forward-key"
	_ = svc.db.Model(&Config{}).Where("id = ?", 1).Update("forward_key", "test-forward-key").Error
	setActive(svc.LoadConfig())

	body, _ := json.Marshal(map[string]interface{}{"model": "x", "messages": []interface{}{}})

	// 无 key → 401
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(body))
	rec := httptest.NewRecorder()
	handleChatCompletions(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("no key: status = %d, want 401", rec.Code)
	}

	// 错误 key → 401
	req = httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer wrong-key")
	rec = httptest.NewRecorder()
	handleChatCompletions(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("wrong key: status = %d, want 401", rec.Code)
	}
}

// TestImageDescribeRouting 验证：纯文本走 LLM；含图请求图片块被 VLM 描述并替换为文本，整体仍走 LLM。
func TestImageDescribeRouting(t *testing.T) {
	var gotLLMModel string
	var gotLLMBody map[string]interface{}
	vlmCalls := 0
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		var req map[string]interface{}
		_ = json.Unmarshal(body, &req)
		// 区分 VLM 上游（路径 /vlm）与 LLM 上游（路径 /llm）
		if strings.HasPrefix(r.URL.Path, "/vlm") {
			vlmCalls++
			// VLM 返回固定描述
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"choices":[{"message":{"content":"一只猫在沙发上"}}]}`))
			return
		}
		gotLLMModel, _ = req["model"].(string)
		gotLLMBody = req
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":"x","object":"chat.completion","choices":[]}`))
	}))
	defer upstream.Close()

	db := setupTestDB(t)
	defer db.Close()
	svc := NewService(db)
	cfg, _ := svc.SaveConfig(SaveRequest{
		LLMApiBase: upstream.URL + "/llm", LLMApiKey: "k", LLMModel: "llm-target",
		VLMApiBase: upstream.URL + "/vlm", VLMApiKey: "k", VLMModel: "vlm-target",
	})
	cfg.ForwardKey = "fk"
	_ = svc.db.Model(&Config{}).Where("id = ?", 1).Update("forward_key", "fk").Error
	setActive(svc.LoadConfig())

	// 纯文本 → LLM，无 VLM 调用
	body, _ := json.Marshal(map[string]interface{}{
		"model": "devproxy",
		"messages": []map[string]interface{}{
			{"role": "user", "content": "hello"},
		},
	})
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer fk")
	rec := httptest.NewRecorder()
	handleChatCompletions(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("text: status = %d, body = %s", rec.Code, rec.Body.String())
	}
	if gotLLMModel != "llm-target" {
		t.Errorf("text routed model = %q, want llm-target", gotLLMModel)
	}
	if vlmCalls != 0 {
		t.Errorf("text should not call VLM, calls = %d", vlmCalls)
	}

	// 含图 → 图片块被描述替换为文本，整体走 LLM
	imgData := []byte("fake-png-bytes-123")
	b64 := base64.StdEncoding.EncodeToString(imgData)
	body, _ = json.Marshal(map[string]interface{}{
		"model": "devproxy",
		"messages": []map[string]interface{}{
			{"role": "user", "content": []map[string]interface{}{
				{"type": "text", "text": "what is this"},
				{"type": "image_url", "image_url": map[string]string{"url": "data:image/png;base64," + b64}},
			}},
		},
	})
	req = httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer fk")
	rec = httptest.NewRecorder()
	handleChatCompletions(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("image: status = %d, body = %s", rec.Code, rec.Body.String())
	}
	// 整体走 LLM
	if gotLLMModel != "llm-target" {
		t.Errorf("image request should route to LLM, got model = %q", gotLLMModel)
	}
	// VLM 被调用一次生成描述
	if vlmCalls != 1 {
		t.Errorf("VLM should be called once, calls = %d", vlmCalls)
	}
	// 图片块被替换为文本块
	msgs := gotLLMBody["messages"].([]interface{})
	m0 := msgs[0].(map[string]interface{})
	content := m0["content"].([]interface{})
	foundDesc := false
	for _, c := range content {
		block := c.(map[string]interface{})
		if block["type"] == "text" && strings.Contains(block["text"].(string), "这里有一个 image") {
			foundDesc = true
			if !strings.Contains(block["text"].(string), "一只猫在沙发上") {
				t.Errorf("description not embedded: %v", block["text"])
			}
		}
		if block["type"] == "image_url" {
			t.Error("image_url block should be replaced by text")
		}
	}
	if !foundDesc {
		t.Errorf("image description text block not found: %v", content)
	}
}

// TestImageCache 验证图片描述缓存：相同图片第二次不调 VLM。
func TestImageCache(t *testing.T) {
	vlmCalls := 0
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		var req map[string]interface{}
		_ = json.Unmarshal(body, &req)
		if strings.HasPrefix(r.URL.Path, "/vlm") {
			vlmCalls++
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"choices":[{"message":{"content":"相同图片描述"}}]}`))
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":"x","object":"chat.completion","choices":[]}`))
	}))
	defer upstream.Close()

	db := setupTestDB(t)
	defer db.Close()
	svc := NewService(db)
	cfg, _ := svc.SaveConfig(SaveRequest{
		LLMApiBase: upstream.URL + "/llm", LLMApiKey: "k", LLMModel: "llm-target",
		VLMApiBase: upstream.URL + "/vlm", VLMApiKey: "k", VLMModel: "vlm-target",
	})
	cfg.ForwardKey = "fk"
	_ = svc.db.Model(&Config{}).Where("id = ?", 1).Update("forward_key", "fk").Error
	setActive(svc.LoadConfig())

	// 清空缓存
	globalImageCache = newImageCache(10 << 20)

	imgData := []byte("same-image-bytes")
	b64 := base64.StdEncoding.EncodeToString(imgData)
	mkBody := func() []byte {
		b, _ := json.Marshal(map[string]interface{}{
			"model": "devproxy",
			"messages": []map[string]interface{}{
				{"role": "user", "content": []map[string]interface{}{
					{"type": "image_url", "image_url": map[string]string{"url": "data:image/png;base64," + b64}},
				}},
			},
		})
		return b
	}
	send := func() {
		req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(mkBody()))
		req.Header.Set("Authorization", "Bearer fk")
		rec := httptest.NewRecorder()
		handleChatCompletions(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
		}
	}

	send() // 第一次：调 VLM
	if vlmCalls != 1 {
		t.Fatalf("first: VLM calls = %d, want 1", vlmCalls)
	}
	send() // 第二次：缓存命中，不调 VLM
	if vlmCalls != 1 {
		t.Errorf("second: VLM calls = %d, want 1 (cache hit)", vlmCalls)
	}
}

// TestImageCacheLRUEvict 验证缓存超上限时淘汰最久未用项。
func TestImageCacheLRUEvict(t *testing.T) {
	c := newImageCache(100) // 上限 100 字节
	c.Set("a", strings.Repeat("x", 40), time.Hour)
	c.Set("b", strings.Repeat("y", 40), time.Hour)
	c.Set("c", strings.Repeat("z", 40), time.Hour)
	// 3*40=120 > 100，应淘汰最早插入的 a（LRU）
	if c.Get("a") != "" {
		t.Error("a should be evicted")
	}
	if c.Get("b") == "" || c.Get("c") == "" {
		t.Error("b and c should remain")
	}
}

// TestImageCacheTTL 验证缓存过期后重新调用。
func TestImageCacheTTL(t *testing.T) {
	c := newImageCache(10 << 20)
	c.Set("k", "desc", time.Millisecond) // 1ms 后过期
	if c.Get("k") != "desc" {
		t.Fatal("entry should be present before expiry")
	}
	time.Sleep(5 * time.Millisecond)
	if c.Get("k") != "" {
		t.Error("expired entry should not be returned")
	}
}

func mustJSON(v interface{}) string {
	b, _ := json.Marshal(v)
	return string(b)
}

// TestModelsEndpoint 验证 /v1/models 返回 LLM/VLM 模型名。
func TestModelsEndpoint(t *testing.T) {
	db := setupTestDB(t)
	defer db.Close()
	svc := NewService(db)
	cfg, _ := svc.SaveConfig(SaveRequest{
		LLMApiBase: "http://x/v1", LLMApiKey: "k", LLMModel: "llm-a",
		VLMApiBase: "http://x/v1", VLMApiKey: "k", VLMModel: "vlm-b",
	})
	setActive(cfg)

	req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	rec := httptest.NewRecorder()
	handleModels(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d", rec.Code)
	}
	var out map[string]interface{}
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	data := out["data"].([]interface{})
	ids := map[string]bool{}
	for _, d := range data {
		ids[d.(map[string]interface{})["id"].(string)] = true
	}
	if !ids["llm-a"] || !ids["vlm-b"] {
		t.Errorf("models = %v, want llm-a and vlm-b", ids)
	}
}

// TestDisabledLLMReturns503 验证 LLM/VLM 都 disabled 时转发返回 503。
func TestDisabledReturns503(t *testing.T) {
	db := setupTestDB(t)
	defer db.Close()
	svc := NewService(db)
	off := false
	cfg, _ := svc.SaveConfig(SaveRequest{
		LLMApiBase: "http://x/v1", LLMApiKey: "k", LLMModel: "m", LLMEnabled: &off,
		VLMApiBase: "http://x/v1", VLMApiKey: "k", VLMModel: "m", VLMEnabled: &off,
	})
	cfg.ForwardKey = "fk"
	setActive(cfg)

	body, _ := json.Marshal(map[string]interface{}{"model": "x", "messages": []interface{}{}})
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer fk")
	rec := httptest.NewRecorder()
	handleChatCompletions(rec, req)

	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503", rec.Code)
	}
}
