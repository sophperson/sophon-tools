package router

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"

	"bmssm/config"
	"bmssm/global"
)

func init() { gin.SetMode(gin.ReleaseMode) }

func TestHealthz(t *testing.T) {
	global.DeviceType = "soc"
	global.DeviceRole = "SE"
	global.DeviceTypeEx = "SE8"
	global.DeviceSnEx = "DEVSN456"
	global.Version = global.BuildInfo{Version: "1.0.0", GitCommit: "abc", BuildTime: "2026-01-01"}

	r := gin.New()
	Register(r)

	w := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}
	var body map[string]string
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("unmarshal: %v body=%s", err, w.Body.String())
	}
	if body["status"] != "ok" {
		t.Fatalf("status=%s", body["status"])
	}
	if body["deviceType"] != "soc" {
		t.Fatalf("deviceType=%s", body["deviceType"])
	}
	if body["role"] != "SE" {
		t.Fatalf("role=%s", body["role"])
	}
	if body["deviceTypeEx"] != "SE8" {
		t.Fatalf("deviceTypeEx=%s", body["deviceTypeEx"])
	}
	if body["sn"] != "DEVSN456" {
		t.Fatalf("sn=%s", body["sn"])
	}
	if body["version"] != "1.0.0" {
		t.Fatalf("version=%s", body["version"])
	}
	if body["uptime"] == "" {
		t.Fatalf("uptime empty")
	}
}

// TestLlmProxyRoutes 验证 llm-proxy 配置路由已注册：
// 无 token 时 GET/PUT 均返回 401（Auth 中间件），而非 404。
func TestLlmProxyRoutes(t *testing.T) {
	gin.SetMode(gin.ReleaseMode)
	// Auth 中间件读取 config.Conf；测试需先初始化（用默认值即可）
	config.LoadFromDir(t.TempDir())
	r := gin.New()
	Register(r)

	// GET 无 token → 401（路由存在且被 Auth 拦截）
	w := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/api/v1/llm-proxy/config", nil)
	r.ServeHTTP(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("GET config without token = %d, want 401", w.Code)
	}

	// PUT 无 token → 401
	w2 := httptest.NewRecorder()
	req2 := httptest.NewRequest(http.MethodPut, "/api/v1/llm-proxy/config", nil)
	r.ServeHTTP(w2, req2)
	if w2.Code != http.StatusUnauthorized {
		t.Fatalf("PUT config without token = %d, want 401", w2.Code)
	}
}
