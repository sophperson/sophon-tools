package system

import (
	"fmt"
	"net/http"
	"net/http/httputil"
	"net/url"
	"time"

	"sophliteos/logger"
	mvc "sophliteos/mvc/core"

	"github.com/gin-gonic/gin"
)

// AiAgentApi AI Agent 功能：picoclaw web 端口探测与转发、本地模型样例。
// LLM/VLM API 配置由 bmssm 的 /api/v1/llm-proxy/config 管理（sophliteos 不再刷新 picoclaw）。
type AiAgentApi struct{}

const defaultPicoclawPort = 18800 // picoclaw web 默认端口

// detectPicoclawPort 探测 picoclaw web 端口：默认 18800，若不可用则探测候选端口。
func detectPicoclawPort() int {
	candidates := []int{defaultPicoclawPort}
	for _, p := range []int{18790, 8081, 18801} {
		if p != defaultPicoclawPort {
			candidates = append(candidates, p)
		}
	}
	for _, p := range candidates {
		if picoclawWebUp(p) {
			return p
		}
	}
	return defaultPicoclawPort
}

// picoclawWebUp 探测端口上是否为 picoclaw web（GET / 返回 2xx/3xx 即视为 up）。
func picoclawWebUp(port int) bool {
	client := &http.Client{Timeout: 3 * time.Second}
	url := fmt.Sprintf("http://127.0.0.1:%d/", port)
	resp, err := client.Get(url)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	return resp.StatusCode >= 200 && resp.StatusCode < 400
}

// Port GET 返回探测到的 picoclaw web 端口。
func (a *AiAgentApi) Port(c *gin.Context) {
	c.JSON(http.StatusOK, mvc.Success(gin.H{"port": detectPicoclawPort()}))
}

// Proxy 反向代理 picoclaw web（保留路径与查询串；供 iframe 同源访问使用）。
func (a *AiAgentApi) Proxy(c *gin.Context) {
	port := detectPicoclawPort()
	target, err := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", port))
	if err != nil {
		c.JSON(http.StatusOK, mvc.Fail(-1, "proxy target error"))
		return
	}
	proxy := httputil.NewSingleHostReverseProxy(target)
	originalDirector := proxy.Director
	proxy.Director = func(req *http.Request) {
		originalDirector(req)
		req.Host = target.Host
	}
	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, e error) {
		logger.Error("picoclaw 代理错误 %s %s: %v", r.Method, r.URL.Path, e)
		w.WriteHeader(http.StatusBadGateway)
	}
	proxy.ServeHTTP(c.Writer, c.Request)
}
