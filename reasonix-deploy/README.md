# Reasonix 部署（sophon-tools MYS-170）

把 **Reasonix** 部署到 SOPHON 测试机（aarch64/SE7，`172.26.166.185`），作为 bmssm
AI Agent 适配器（`mvc/agentproxy`）的唯一 ACP 后端。**放弃 picoclaw** 作为 AI Agent 链路。

不改 Reasonix 源码，只通过 ACP v1（NDJSON JSON-RPC 2.0 over stdin/stdout）对接。

## 架构

```
浏览器 (web-client / sophliteos Agent 页内嵌)
   │  WS :18990  /agent/ws （子协议 token.<forward_key>）
   ▼
bmssm.mvc/agentproxy  (ws.go 端点 + protocol.go 协议映射 + session 管理)
   │  ACP v1 (stdin/stdout)
   ▼
reasonix acp  (进程由 agentproxy os/exec 托管，崩溃自动重启)
   │  OpenAI over HTTP（provider=sophnet，base_url=本机 llmproxy）
   ▼
bmssm.llmproxy (:18080/v1/chat/completions)  →  sophnet DeepSeek-V4-Flash-0731
```

## 组件与关键配置

### 1. Reasonix 二进制

- 交叉编译 arm64：`GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -o reasonix-arm64 ./cmd/reasonix`
- 部署位置：`/opt/sophon/reasonix/bin/reasonix`
- Reasonix 由 `bmssm` 的 `mvc/agentproxy`（process.go）以 `reasonix acp` 托管，
  崩溃退避自动重启（1s→30s）。

### 2. Reasonix 用户配置 `/root/.reasonix/config.toml`

reasonix acp 以 root（bmssm systemd 环境）运行，读 `$HOME/.reasonix/config.toml`。

```toml
default_model = "sophnet"

[[providers]]
name           = "sophnet"
kind           = "openai"
base_url       = "http://127.0.0.1:18080/v1"   # 本机 llmproxy（OpenAI shim）
model          = "DeepSeek-V4-Flash-0731"
api_key_env    = "DEEPSEEK_API_KEY"
reasoning_protocol = "openai"
context_window = 131072

[sandbox]
bash = "off"   # 测试机无 bubblewrap；关闭 bash 沙箱（不关则 turn 以 error 结束）
```

关键点：
- **`base_url` 必须带 `/v1`**：reasonix kind=openai 在 base_url 后追加 `/chat/completions`，
  不带 `/v1` 会 404（llmproxy 只暴露 `/v1/chat/completions`）。
- **`[sandbox] bash = "off"`**：本机无 bubblewrap，reasonix 默认 `enforce` 会拒绝
  unconfined shell，导致整个 turn 以 `stopReason=error` 结束。必须关闭才能产出消息。
- **`DEEPSEEK_API_KEY` 由 bmssm systemd 注入**（值 = `forward_key`），reasonix 原子进程
  继承该环境，实现 forward key 透传认证 llmproxy，`config.toml` 不写明文密钥。

### 3. bmssm `agentproxy` 段（`/opt/sophon/bmssm/config/bmssm.yaml`）

```yaml
agentproxy:
  enabled: true          # Reasonix 为唯一 AI Agent 后端
  listenIP: 0.0.0.0      # WS 绑定全部网卡（浏览器经外网 IP 访问 18990）
  port: 18990            # WS 端点端口 /agent/ws
  binaryPath: /opt/sophon/reasonix/bin/reasonix
  workDir: /home/linaro  # reasonix 会话 cwd
  model: ""              # 空 = reasonix 默认（sophnet 提供商）
  restartBackoffMax: 30s
```

- `listenIP: 0.0.0.0`：浏览器从外部 IP（如 `172.26.166.185`）连 WS，`127.0.0.1` 会
  `ERR_CONNECTION_REFUSED`。
- bmssm 需用 **cgo musl 静态**交叉编译（`go-sqlite3` 依赖 cgo）：脚本
  `source/pbmssm/build/build-bmssm-arm64.sh`。`CGO_ENABLED=0` 无法打开 sqlite，
  llmproxy 配置/会话持久化会失效。
- 若本机 8080/sophliteos 已由内嵌 web-chat 承载，前端 `wsUrl` 指向 `:18990/agent/ws`。

### 4. web-client / sophliteos 内嵌

- 部署 reasonix 版 web-client：`bash deploy-web-chat.sh --embedded`（注 forward key 生成 config.js）
- 让 sophliteos「AI Agent / Agent」页 iframe 指向内嵌 web-chat：
  `bash web-client-deploy/apply-ai-agent-webchat.sh --embedded`

## 验证（端到端）

1. **ACP 握手**：bmssm 日志出现 `agentproxy: initialize ok protocolVersion=1`。
2. **WS 直连**：子协议 `token.<forward_key>` 连 `ws://<host>:18990/agent/ws`，
   发 `message.send`，应陆续收到 `session.create → typing.start → message.create(kind=thought) →
   message.create(kind=text)`。
3. **浏览器**：访问 sophliteos Agent 页（或 `http://<host>:8080/resource/web-chat/`），
   发消息，验证：文本流式 / 思考过程折叠 / 工具调用折叠 / Markdown+代码高亮 /
   多会话 / 断线重连 / 浅深主题 / 图片上传按钮隐藏。
4. **工具调用**：reasonix 以 `bash · execute · completed` 形态出现在展开的工具调用折叠块。

## 部署脚本

`reasonix-deploy/deploy-reasonix.sh` 一键完成：传 `--reasonix-bin <本地 arm64 二进制>`
`--bmssm-bin <本地 bmssm arm64 二进制>` 即可在全新测试机上复现本部署。

## 注意

- 不卸载 picoclaw，仅不再作为 AI Agent 后端（gateway 18790 / launcher 18800 保留可访问）。
- Reasonix 无 VLM 图片能力：前端图片上传按钮已隐藏。
