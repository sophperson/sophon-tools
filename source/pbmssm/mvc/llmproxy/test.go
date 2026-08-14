package llmproxy

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"

	"bmssm/pkg/response"
)

// TestResult 单项测试结果。
type TestResult struct {
	Name    string `json:"name"`    // 测试项名称
	OK      bool   `json:"ok"`      // 是否通过
	Message string `json:"message"` // 详情/错误信息
}

// TestResponse 一键测试响应。
type TestResponse struct {
	Results []TestResult `json:"results"`
	AllOK   bool         `json:"allOk"`
}

// RunTest POST /api/v1/llm-proxy/test
// 一键测试两项：
//  1. 带图分发：构造含图请求 → 图片经 VLM 描述 → 文本插入 → 走 LLM，验证分发链路
//  2. LLM 推理：纯文本请求走 LLM，验证推理链路
func (tc *Controller) RunTest(c *gin.Context) {
	cfg := tc.svc.LoadConfig()
	results := []TestResult{
		testImageDispatch(c.Request.Context(), cfg),
		testLLMInference(c.Request.Context(), cfg),
	}
	allOK := true
	for _, r := range results {
		if !r.OK {
			allOK = false
		}
	}
	c.JSON(http.StatusOK, response.OK(TestResponse{Results: results, AllOK: allOK}))
}

// testImageDispatch 测试带图分发：图片描述化 + LLM 转发。
func testImageDispatch(ctx context.Context, cfg Config) TestResult {
	name := "带图分发"
	llm := cfg.LLM()
	vlm := cfg.VLM()
	if !llm.Enabled || llm.ApiBase == "" || llm.ModelName == "" {
		return TestResult{Name: name, OK: false, Message: "LLM 上游未配置或未启用"}
	}
	// VLM 未配置（非 Sophnet 本地 LLM 场景）：跳过描述化，直接带 image 转发给本地 LLM。
	if !vlm.Enabled || vlm.ApiBase == "" || vlm.ModelName == "" {
		body, statusCode, err := forwardLLM(ctx, buildImageDispatchReq(), llm, vlm)
		if err != nil {
			return TestResult{Name: name, OK: false, Message: "转发失败: " + err.Error()}
		}
		if statusCode != http.StatusOK {
			return TestResult{Name: name, OK: false, Message: fmt.Sprintf("上游返回 %d: %s", statusCode, truncate(string(body), 200))}
		}
		return TestResult{Name: name, OK: true, Message: "VLM 未配置，图片直接透传本地 LLM 成功: " + truncate(string(body), 200)}
	}
	// 注意：messages 必须用 []interface{} 构造（与 JSON 反序列化后类型一致），
	// 否则 describeImagesInRequest 的 []interface{} 类型断言会失败，图片不会被描述化。
	png := testPNG()
	b64 := base64.StdEncoding.EncodeToString(png)
	req := map[string]interface{}{
		"model": "devproxy",
		"messages": []interface{}{
			map[string]interface{}{
				"role": "user",
				"content": []interface{}{
					map[string]interface{}{"type": "text", "text": "请用一句话描述这张图片"},
					map[string]interface{}{"type": "image_url", "image_url": map[string]interface{}{"url": "data:image/png;base64," + b64}},
				},
			},
		},
	}
	body, statusCode, err := forwardLLM(ctx, req, llm, vlm)
	if err != nil {
		return TestResult{Name: name, OK: false, Message: "转发失败: " + err.Error()}
	}
	if statusCode != http.StatusOK {
		return TestResult{Name: name, OK: false, Message: fmt.Sprintf("上游返回 %d: %s", statusCode, truncate(string(body), 200))}
	}
	return TestResult{Name: name, OK: true, Message: "图片描述化 + LLM 转发成功: " + truncate(string(body), 200)}
}

// buildImageDispatchReq 构造带图请求（内嵌一张 1x1 PNG 测试图）。
func buildImageDispatchReq() map[string]interface{} {
	png := testPNG()
	b64 := base64.StdEncoding.EncodeToString(png)
	return map[string]interface{}{
		"model": "devproxy",
		"messages": []interface{}{
			map[string]interface{}{
				"role": "user",
				"content": []interface{}{
					map[string]interface{}{"type": "text", "text": "请用一句话描述这张图片"},
					map[string]interface{}{"type": "image_url", "image_url": map[string]interface{}{"url": "data:image/png;base64," + b64}},
				},
			},
		},
	}
}

// testLLMInference 测试纯文本 LLM 推理。
func testLLMInference(ctx context.Context, cfg Config) TestResult {
	name := "LLM 推理"
	llm := cfg.LLM()
	if !llm.Enabled || llm.ApiBase == "" || llm.ModelName == "" {
		return TestResult{Name: name, OK: false, Message: "LLM 上游未配置或未启用"}
	}
	req := map[string]interface{}{
		"model": "devproxy",
		"messages": []map[string]interface{}{
			{"role": "user", "content": "请回复：OK"},
		},
	}
	body, statusCode, err := forwardLLM(ctx, req, llm, Config{}.VLM())
	if err != nil {
		return TestResult{Name: name, OK: false, Message: "转发失败: " + err.Error()}
	}
	if statusCode != http.StatusOK {
		return TestResult{Name: name, OK: false, Message: fmt.Sprintf("上游返回 %d: %s", statusCode, truncate(string(body), 200))}
	}
	return TestResult{Name: name, OK: true, Message: "LLM 推理成功: " + truncate(string(body), 200)}
}

// forwardLLM 核心转发：图片描述化（可选）+ model 请求优先/默认兜底 + 调 LLM 上游，返回响应体与状态码。
// 供 handleChatCompletions 与测试接口共用。
// VLM 未配置时（!vlm.Enabled || ApiBase=="" || ModelName==""）跳过描述化：
// 本地 LLM 场景（LLM API Base 非 Sophnet）直接透传含 image 的 body 给本地 API。
func forwardLLM(ctx context.Context, req map[string]interface{}, llm, vlm ProviderConfig) ([]byte, int, error) {
	if !llm.Enabled || llm.ApiBase == "" || llm.ModelName == "" {
		return nil, 0, fmt.Errorf("llm upstream not configured")
	}
	// 图片描述化（若含图）：VLM 已配置才描述；未配置则原样透传（本地 LLM 直接吃图）
	if vlm.Enabled && vlm.ApiBase != "" && vlm.ModelName != "" {
		if err := describeImagesInRequest(req, vlm); err != nil {
			return nil, 0, fmt.Errorf("image describe failed: %w", err)
		}
	}
	// 覆盖下游请求（需求：删除前端开关，默认一律直接覆盖）：
	// 无论下游请求里 model 是什么，转发时一律强制替换为配置的默认模型名。
	req["model"] = llm.ModelName
	body, _ := json.Marshal(req)

	upstreamURL := strings.TrimRight(llm.ApiBase, "/") + "/chat/completions"
	proxyReq, err := http.NewRequestWithContext(ctx, http.MethodPost, upstreamURL, bytes.NewReader(body))
	if err != nil {
		return nil, 0, err
	}
	proxyReq.Header.Set("Content-Type", "application/json")
	if llm.ApiKey != "" {
		proxyReq.Header.Set("Authorization", "Bearer "+llm.ApiKey)
	}

	client := &http.Client{
		Transport: &http.Transport{
			DisableCompression:    true,
			ResponseHeaderTimeout: 60 * time.Second,
		},
		Timeout: 120 * time.Second,
	}
	resp, err := client.Do(proxyReq)
	if err != nil {
		return nil, 0, fmt.Errorf("upstream request failed: %w", err)
	}
	defer resp.Body.Close()
	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, resp.StatusCode, err
	}
	return respBody, resp.StatusCode, nil
}

// testPNG 返回一张 128x128 纯色 PNG（测试用，满足 VLM 最小尺寸限制）。
func testPNG() []byte {
	// 128x128 纯蓝 PNG（base64）
	const b64 = "iVBORw0KGgoAAAANSUhEUgAAAIAAAACACAIAAABMXPacAAAA+UlEQVR4nO3RQQ0AIAzAwAlDDmKRhYw9ekkFNLk592mxWT+IBwBAOwAA2gEA0A4AgHYAALQDAKAdAADtAABoBwBAOwAA2gEA0A4AgHYAALQDAKAdAADtAABoBwBAOwAA2gEA0A4AgHYAALQDAKAdAADtAABoBwBAOwAA2gEA0A4AgHYAALQDAKAdAADtAABoBwBAOwAA2gEA0A4AgHYAALQDAKAdAADtAABoBwBAOwAA2gEA0A4AgHYAALQDAKAdAADtAABoBwBAOwAA2gEA0A4AgHYAALQDAKAdAADtAABoBwBAOwAA2gEA0A4AgHYAALQDAKAdAADtPm23BUfg9BCFAAAAAElFTkSuQmCC"
	data, _ := base64.StdEncoding.DecodeString(b64)
	return data
}
