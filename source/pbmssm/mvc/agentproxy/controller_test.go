package agentproxy

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
)

func init() {
	gin.SetMode(gin.TestMode)
}

// TestServiceStatusModuleNotStarted 未初始化 agentproxy 时 status 应给出 disabled/stopped，
// 不 panic。
func TestServiceStatusModuleNotStarted(t *testing.T) {
	globalMu.Lock()
	old := globalMod
	globalMod = nil
	globalMu.Unlock()
	defer func() {
		globalMu.Lock()
		globalMod = old
		globalMu.Unlock()
	}()

	ctrl := &Controller{}
	rec := httptest.NewRecorder()
	ctx, _ := gin.CreateTestContext(rec)
	ctx.Request = httptest.NewRequest(http.MethodGet, "/api/v1/agent/service/status", nil)
	ctrl.GetServiceStatus(ctx)
	if rec.Code != http.StatusOK {
		t.Fatalf("status code = %d, want 200", rec.Code)
	}
	if s := rec.Body.String(); s == "" {
		t.Fatal("empty body")
	}
}

// TestServiceActionValidation invalid/不支持动作应报错，不 panic。
func TestServiceActionValidation(t *testing.T) {
	globalMu.Lock()
	old := globalMod
	globalMod = nil
	globalMu.Unlock()
	defer func() {
		globalMu.Lock()
		globalMod = old
		globalMu.Unlock()
	}()

	cases := []struct {
		action string
		code   int
	}{
		{"", 400},   // 空动作
		{"rm", 400}, // 非法动作
		{"enable", 400},
		{"disable", 400},
	}
	for _, c := range cases {
		rec := httptest.NewRecorder()
		ctx, _ := gin.CreateTestContext(rec)
		body := `{"action": "` + c.action + `"}`
		ctx.Request = httptest.NewRequest(http.MethodPost, "/api/v1/agent/service/action", strings.NewReader(body))
		ctx.Request.Header.Set("Content-Type", "application/json")
		ctrl := &Controller{}
		ctrl.ServiceAction(ctx)
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("action %q: code = %d, want 400", c.action, rec.Code)
		}
	}
}
