package llmproxy

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"bmssm/config"
	"bmssm/logger"
)

// server 状态：配置变更时通过 UpdateServer 热更新（替换原子指针）。
var (
	mu        sync.RWMutex
	startMu   sync.Mutex
	activeSrv *http.Server
	activeCfg Config
)

// StartServer 启动（或刷新）LLM 转发 server。
// 首次调用启动 goroutine；后续调用热更新配置（上游地址/key/目标模型）。
// initializer 在 bmssm 启动时调用一次；配置保存接口也会调用。
func StartServer(cfg Config) {
	UpdateServer(cfg)
}

// UpdateServer 更新配置并应用。若 server 未启动则启动（绑定配置的 listenIP:port）。
// enabled=false 时停止 server（若在运行）。串行化启动避免并发 double-start。
func UpdateServer(cfg Config) {
	mu.Lock()
	activeCfg = cfg
	// 任一上游启用即启动转发 server
	enabled := cfg.LLMEnabled || cfg.VLMEnabled
	needStart := activeSrv == nil && enabled
	needStop := activeSrv != nil && !enabled
	mu.Unlock()

	if needStop {
		stopServer()
		return
	}
	if !needStart {
		logger.Info("llm proxy config updated: llm=%s vlm=%s", cfg.LLMModel, cfg.VLMModel)
		return
	}

	// 需要启动：加锁并二次检查（另一 goroutine 可能已启动）
	startMu.Lock()
	defer startMu.Unlock()
	mu.RLock()
	already := activeSrv != nil
	mu.RUnlock()
	if already {
		logger.Info("llm proxy config updated: llm=%s vlm=%s", cfg.LLMModel, cfg.VLMModel)
		return
	}
	startServer(cfg)
}

// startServer 在独立 goroutine 启动转发 server。
func startServer(cfg Config) {
	conf := &config.Conf
	conf.RLock()
	listenIP := conf.GetViper().GetString("llm-proxy.listenIP")
	if listenIP == "" {
		listenIP = "127.0.0.1"
	}
	port := conf.GetViper().GetInt("llm-proxy.port")
	if port == 0 {
		port = 18080
	}
	conf.RUnlock()

	mux := http.NewServeMux()
	mux.HandleFunc("/v1/chat/completions", handleChatCompletions)
	mux.HandleFunc("/v1/models", handleModels)

	addr := net.JoinHostPort(listenIP, strconv.Itoa(port))
	srv := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 30 * time.Second,
	}

	mu.Lock()
	activeSrv = srv
	mu.Unlock()

	logger.Info("llm proxy server listening on %s (llm=%s vlm=%s)",
		addr, cfg.LLMModel, cfg.VLMModel)

	go func() {
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			logger.Error("llm proxy server failed: %v", err)
		}
	}()
}

// stopServer 停止转发 server（若有）。
func stopServer() {
	mu.Lock()
	srv := activeSrv
	activeSrv = nil
	mu.Unlock()
	if srv != nil {
		logger.Info("stopping llm proxy server on %s", srv.Addr)
		_ = srv.Close()
	}
}

// currentConfig 返回当前生效配置（原子读）。
func currentConfig() Config {
	mu.RLock()
	defer mu.RUnlock()
	return activeCfg
}

// handleModels GET /v1/models —— 返回当前配置的 LLM/VLM 模型名。
func handleModels(w http.ResponseWriter, r *http.Request) {
	cfg := currentConfig()
	models := []map[string]interface{}{}
	if cfg.LLMModel != "" {
		models = append(models, map[string]interface{}{"id": cfg.LLMModel, "object": "model", "owned_by": "bmssm-llm-proxy"})
	}
	if cfg.VLMModel != "" {
		models = append(models, map[string]interface{}{"id": cfg.VLMModel, "object": "model", "owned_by": "bmssm-llm-proxy"})
	}
	if len(models) == 0 {
		models = append(models, map[string]interface{}{"id": "devproxy", "object": "model", "owned_by": "bmssm-llm-proxy"})
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]interface{}{"object": "list", "data": models})
}

// handleChatCompletions POST /v1/chat/completions —— OpenAI 兼容转发。
// 流程（图片描述化，防止含图历史进入 VLM 导致推理质量下滑）：
//  1. 校验入站 Authorization: Bearer <forward_key>（不匹配 → 401）
//  2. 遍历所有 messages 的 content：
//     - 文本块 → 保留
//     - 图片块（image_url/image）→ 提取图片数据 → 哈希查缓存：
//         * 命中 → 复用描述
//         * 未命中 → 调 VLM 生成详细描述 → 缓存
//       用文本块替换图片块：{type:text, text:"这里有一个 image，其内容如下：<描述>"}
//  3. 所有请求统一路由到 LLM（替换 model 为 LLM model_name）
//  4. 用 bmssm 内部存储的 LLM 上游 key 向供应商转发
func handleChatCompletions(w http.ResponseWriter, r *http.Request) {
	cfg := currentConfig()

	// 1. 转发 key 校验
	if cfg.ForwardKey == "" || !validForwardKey(r, cfg.ForwardKey) {
		http.Error(w, "unauthorized: invalid forward key", http.StatusUnauthorized)
		return
	}

	body, err := io.ReadAll(r.Body)
	r.Body.Close()
	if err != nil {
		http.Error(w, "read body failed", http.StatusInternalServerError)
		return
	}

	// 2. 解析请求体
	var req map[string]interface{}
	if err := json.Unmarshal(body, &req); err != nil || req == nil {
		http.Error(w, "invalid request body: expected JSON", http.StatusBadRequest)
		return
	}

	// 3. 核心转发：图片描述化 + 替换 model + 调 LLM
	llm := cfg.LLM()
	if !llm.Enabled || llm.ApiBase == "" || llm.ModelName == "" {
		http.Error(w, "llm upstream not configured", http.StatusServiceUnavailable)
		return
	}
	respBody, statusCode, err := forwardLLM(r.Context(), req, llm, cfg.VLM())
	if err != nil {
		logger.Error("forward failed: %v", err)
		http.Error(w, "forward failed: "+err.Error(), http.StatusBadGateway)
		return
	}

	// 4. 透传响应
	w.WriteHeader(statusCode)
	_, _ = w.Write(respBody)
}

// validForwardKey 校验请求携带的转发 key 与配置一致（Bearer <key>）。
func validForwardKey(r *http.Request, want string) bool {
	h := r.Header.Get("Authorization")
	if !strings.HasPrefix(h, "Bearer ") {
		return false
	}
	got := strings.TrimSpace(strings.TrimPrefix(h, "Bearer "))
	return got != "" && got == want
}

// describeImagesInRequest 遍历所有 message，把图片块替换为文本描述块。
// 返回错误时请求体可能被部分修改（调用方直接放弃）。
func describeImagesInRequest(req map[string]interface{}, vlm ProviderConfig) error {
	messages, ok := req["messages"].([]interface{})
	if !ok {
		return nil
	}
	for _, m := range messages {
		msg, ok := m.(map[string]interface{})
		if !ok {
			continue
		}
		if err := describeContent(msg["content"], vlm); err != nil {
			return err
		}
	}
	return nil
}

// describeContent 递归处理 content：文本保留，图片块替换为文本描述块。
func describeContent(content interface{}, vlm ProviderConfig) error {
	blocks, ok := content.([]interface{})
	if !ok {
		return nil
	}
	for i, block := range blocks {
		b, ok := block.(map[string]interface{})
		if !ok {
			continue
		}
		if isImageBlock(b) {
			desc, err := describeImageBlock(b, vlm)
			if err != nil {
				return err
			}
			// 用文本块替换图片块
			blocks[i] = map[string]interface{}{
				"type": "text",
				"text": "这里有一个 image，其内容如下：" + desc,
			}
			continue
		}
		// 嵌套 content（tool_result 等）
		if nested, ok := b["content"]; ok {
			if err := describeContent(nested, vlm); err != nil {
				return err
			}
		}
	}
	return nil
}

// describeImageBlock 对单个图片块生成文本描述：
//  1. 提取图片数据（data URL 解码 / http 拉取）
//  2. 计算 sha256 哈希，查缓存；命中直接复用
//  3. 未命中：构造 VLM 请求（含图 + 描述 prompt），解析响应
//  4. 缓存描述并返回
func describeImageBlock(b map[string]interface{}, vlm ProviderConfig) (string, error) {
	imgData, err := extractImageData(b)
	if err != nil {
		return "", err
	}
	hash := hashImage(imgData)

	// 缓存命中
	if desc := globalImageCache.Get(hash); desc != "" {
		logger.Info("image cache hit: hash=%s", hash[:12])
		return desc, nil
	}

	// 未命中：调 VLM
	if !vlm.Enabled || vlm.ApiBase == "" || vlm.ModelName == "" {
		return "", fmt.Errorf("vlm upstream not configured for image description")
	}
	desc, err := callVLMDescribe(vlm, imgData)
	if err != nil {
		return "", err
	}
	desc = strings.TrimSpace(desc)
	if desc == "" {
		desc = "(无法识别图片内容)"
	}
	globalImageCache.Set(hash, desc, 24*time.Hour)
	logger.Info("image described: hash=%s len=%d", hash[:12], len(desc))
	return desc, nil
}

// extractImageData 从图片块提取原始字节：
//   - image_url.url 为 data URL（data:image/...;base64,xxx）→ base64 解码
//   - image_url.url 为 http(s) URL → 拉取
//   - image 块的 source.data 为 base64
func extractImageData(b map[string]interface{}) ([]byte, error) {
	if b["type"] == "image" {
		// Anthropic 格式：source.data (base64)
		if src, ok := b["source"].(map[string]interface{}); ok {
			if data, ok := src["data"].(string); ok {
				return base64.StdEncoding.DecodeString(data)
			}
		}
	}
	// OpenAI 格式：image_url.url
	iu, ok := b["image_url"].(map[string]interface{})
	if !ok {
		// 兼容 string 形式
		if s, ok := b["image_url"].(string); ok {
			iu = map[string]interface{}{"url": s}
		} else {
			return nil, fmt.Errorf("image block missing image_url")
		}
	}
	urlStr, _ := iu["url"].(string)
	if urlStr == "" {
		return nil, fmt.Errorf("image_url missing url")
	}
	if strings.HasPrefix(urlStr, "data:") {
		// data URL: data:[mime];base64,<data>
		comma := strings.Index(urlStr, ",")
		if comma < 0 {
			return nil, fmt.Errorf("invalid data URL")
		}
		return base64.StdEncoding.DecodeString(urlStr[comma+1:])
	}
	// http(s) URL：拉取
	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Get(urlStr)
	if err != nil {
		return nil, fmt.Errorf("fetch image url: %w", err)
	}
	defer resp.Body.Close()
	return io.ReadAll(resp.Body)
}

// hashImage 计算图片数据 sha256。
func hashImage(data []byte) string {
	h := sha256.Sum256(data)
	return hex.EncodeToString(h[:])
}

// callVLMDescribe 调用 VLM 上游生成图片描述（OpenAI 兼容 /chat/completions）。
func callVLMDescribe(vlm ProviderConfig, imgData []byte) (string, error) {
	b64 := base64.StdEncoding.EncodeToString(imgData)
	body := map[string]interface{}{
		"model": vlm.ModelName,
		"messages": []map[string]interface{}{
			{
				"role": "user",
				"content": []map[string]interface{}{
					{"type": "text", "text": "请用中文详细描述这张图片的内容，包括物体、场景、文字等细节。只输出描述，不要其他内容。"},
					{"type": "image_url", "image_url": map[string]string{"url": "data:image/png;base64," + b64}},
				},
			},
		},
		"max_tokens": 800,
	}
	bodyBytes, _ := json.Marshal(body)

	upstreamURL := strings.TrimRight(vlm.ApiBase, "/") + "/chat/completions"
	req, err := http.NewRequest(http.MethodPost, upstreamURL, bytes.NewReader(bodyBytes))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	if vlm.ApiKey != "" {
		req.Header.Set("Authorization", "Bearer "+vlm.ApiKey)
	}

	client := &http.Client{Timeout: 120 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("vlm request failed: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		rb, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("vlm returned %d: %s", resp.StatusCode, truncate(string(rb), 200))
	}
	var out struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return "", fmt.Errorf("vlm response parse: %w", err)
	}
	if len(out.Choices) == 0 {
		return "", fmt.Errorf("vlm returned no choices")
	}
	return out.Choices[0].Message.Content, nil
}

// isImageBlock 判断 block 是否图片块。
func isImageBlock(b map[string]interface{}) bool {
	switch b["type"] {
	case "image", "image_url":
		return true
	}
	return false
}

// --- 写入本地 picoclaw -------------------------------------------------------

// devproxyKeyPath 返回 picoclaw devproxy.key 路径。
// 优先 SOPHON_PICOCLAW_HOME，其次 /home/*/picoclaw-deploy 探测，最后当前用户主目录。
func devproxyKeyPath() (string, error) {
	var home string
	if h := os.Getenv("SOPHON_PICOCLAW_HOME"); h != "" {
		home = h
	} else if entries, err := os.ReadDir("/home"); err == nil {
		for _, e := range entries {
			if e.IsDir() {
				candidate := filepath.Join("/home", e.Name(), ".picoclaw")
				if st, err := os.Stat(candidate); err == nil && st.IsDir() {
					home = filepath.Dir(candidate)
					break
				}
			}
		}
	}
	if home == "" {
		return "", fmt.Errorf("cannot locate picoclaw home")
	}
	return filepath.Join(home, ".picoclaw", "devproxy.key"), nil
}

// WriteForwardKeyToPicoclaw 把转发 key 写入 /home/<user>/.picoclaw/devproxy.key，
// 并重启 picoclaw gateway（及 launcher，若在运行）。
func WriteForwardKeyToPicoclaw(key string) error {
	path, err := devproxyKeyPath()
	if err != nil {
		return err
	}
	// 写文件（0600）
	if err := os.WriteFile(path, []byte(key), 0o600); err != nil {
		return fmt.Errorf("write devproxy.key: %w", err)
	}
	// 重启 gateway：picoclaw gateway restart（若 launcher 在运行则先重启 launcher）
	restartPicoclaw()
	return nil
}

// restartPicoclaw 重启 picoclaw：先重启 launcher（触发 gateway 随启），
// 若无 launcher 则直接重启 gateway 进程。
func restartPicoclaw() {
	// 1. 尝试 pkill picoclaw-launcher（SIGTERM）
	if out, err := exec.Command("pkill", "-TERM", "-f", "picoclaw-launcher").CombinedOutput(); err == nil {
		logger.Info("picoclaw-launcher stopped: %s", string(out))
	}
	// 2. 尝试 pkill gateway
	if out, err := exec.Command("pkill", "-TERM", "-f", "picoclaw gateway").CombinedOutput(); err == nil {
		logger.Info("picoclaw gateway stopped: %s", string(out))
	}
	// 3. 等待端口释放
	waitPortRelease(18790, 10*time.Second)
	waitPortRelease(18800, 10*time.Second)
	// 4. 若存在 launcher 则重新拉起
	home := picoclawHomeDir()
	if home != "" {
		launcher := filepath.Join(home, "picoclaw-deploy", "picoclaw-launcher")
		if st, err := os.Stat(launcher); err == nil && !st.IsDir() {
			cmd := exec.Command(launcher, "-public", "-no-browser")
			cmd.Dir = filepath.Dir(launcher)
			cmd.Env = append(os.Environ(), "HOME="+home)
			if err := cmd.Start(); err == nil {
				_ = cmd.Process.Release()
				logger.Info("picoclaw-launcher restarted (pid=%d)", cmd.Process.Pid)
				return
			}
		}
	}
	logger.Warn("picoclaw launcher not found; gateway restart may be required manually")
}

// picoclawHomeDir 返回 picoclaw 主目录（/home/<user>）。
func picoclawHomeDir() string {
	if h := os.Getenv("SOPHON_PICOCLAW_HOME"); h != "" {
		return h
	}
	if entries, err := os.ReadDir("/home"); err == nil {
		for _, e := range entries {
			if e.IsDir() {
				candidate := filepath.Join("/home", e.Name(), "picoclaw-deploy")
				if st, err := os.Stat(candidate); err == nil && st.IsDir() {
					return filepath.Join("/home", e.Name())
				}
			}
		}
	}
	return ""
}

// waitPortRelease 轮询等待端口不再监听。
func waitPortRelease(port int, timeout time.Duration) {
	deadline := time.Now().Add(timeout)
	addr := fmt.Sprintf("127.0.0.1:%d", port)
	for time.Now().Before(deadline) {
		conn, err := net.DialTimeout("tcp", addr, 500*time.Millisecond)
		if err != nil {
			return
		}
		conn.Close()
		time.Sleep(300 * time.Millisecond)
	}
}

// flushWriter SSE 透传用：每次 Write 后 Flush。
type flushWriter struct {
	w http.ResponseWriter
	f http.Flusher
}

func (fw *flushWriter) Write(p []byte) (int, error) {
	n, err := fw.w.Write(p)
	if fw.f != nil {
		fw.f.Flush()
	}
	return n, err
}
