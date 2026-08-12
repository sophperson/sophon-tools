package llmproxy

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
)

// TestGetSophpicoclawStatusNoPanic 无 sophpicoclaw/systemd 环境也不应 panic。
// CI 上 systemctl 命令可能失败，函数应返回状态（字段为空）而非崩溃。
func TestGetSophpicoclawStatusNoPanic(t *testing.T) {
	st, err := GetSophpicoclawStatus()
	if err != nil {
		// 允许错误（无 systemd 环境），但不允许 panic 已由 test 框架保证
		t.Logf("GetSophpicoclawStatus error: %v", err)
		return
	}
	if st == nil {
		t.Fatal("status is nil")
	}
}

// TestActionSophpicoclawValidates 动作白名单：非法动作必须被拒绝。
func TestActionSophpicoclawValidates(t *testing.T) {
	bad := []string{"rm -rf /", "", "systemctl", "daemon-reload", "status;reboot"}
	for _, a := range bad {
		if err := ActionSophpicoclaw(a); err == nil {
			t.Fatalf("expected invalid action %q to be rejected", a)
		}
	}
	// 合法动作在无 systemd 环境可能报错（unit 不存在），但不应是“非法动作”错误
	for _, a := range []string{"start", "stop", "restart", "enable", "disable"} {
		err := ActionSophpicoclaw(a)
		if err != nil && strings.Contains(err.Error(), "invalid action") {
			t.Fatalf("valid action %q rejected as invalid: %v", a, err)
		}
	}
}

// TestServiceStatusEndpoint 验证 status 端点返回 JSON 结构。
func TestServiceStatusEndpoint(t *testing.T) {
	gin.SetMode(gin.TestMode)
	ctrl := &Controller{}
	rec := httptest.NewRecorder()
	ctx, _ := gin.CreateTestContext(rec)
	req := httptest.NewRequest(http.MethodGet, "/api/v1/llm-proxy/service/status", nil)
	ctx.Request = req
	ctrl.GetServiceStatus(ctx)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	var out struct {
		Result ServiceStatus `json:"result"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if out.Result.ActiveState == "" && out.Result.MainPID == "" {
		// 允许空状态（无 systemd），但结构必须正确
	}
}

// TestServiceActionEndpoint 非法动作经 HTTP 端点返回 400。
func TestServiceActionEndpointRejectsInvalid(t *testing.T) {
	gin.SetMode(gin.TestMode)
	ctrl := &Controller{}
	rec := httptest.NewRecorder()
	ctx, _ := gin.CreateTestContext(rec)
	body := strings.NewReader(`{"action":"rm -rf /"}`)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/llm-proxy/service/action", body)
	req.Header.Set("Content-Type", "application/json")
	ctx.Request = req
	ctrl.ServiceAction(ctx)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400, body = %s", rec.Code, rec.Body.String())
	}
}
