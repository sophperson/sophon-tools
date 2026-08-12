#!/usr/bin/env bash
# deploy-reasonix.sh — 部署 Reasonix 到测试机并接入 bmssm agentproxy（MYS-170）
#
# 目标：让 Reasonix 成为唯一 AI Agent 后端（抛弃 picoclaw）。流程：
#   1) 把 reasonix (linux-arm64) 二进制放到 /opt/sophon/reasonix/bin/reasonix
#   2) 写 Reasonix 用户配置 /root/.reasonix/config.toml：
#      · provider 指向本机 llmproxy（127.0.0.1:18080，OpenAI shim，转发 sophnet DeepSeek）
#      · [sandbox] bash="off"（测试机无 bubblewrap；不关则 turn 以 error 结束）
#   3) 把 DEEPSEEK_API_KEY（= bmssm llm_proxy_config.forward_key）注入 bmssm systemd 环境
#      （reasonix 子进程继承该环境，实现 forward key 透传，避免在 config 里写死 key）
#   4) 在 bmssm.yaml 启用 agentproxy（enabled/path/port/listenIP）并重启 bmssm
#   5) 验证：reasonix acp initialize 握手、WS 18990 监听
#
# 前置：本机已交叉编译出 bmssm(release/bmssm) 与 reasonix-arm64 二进制。
# 用法：bash deploy-reasonix.sh [--host <ssh-host>] [--user <ssh-user>] [--pass <ssh-pass>]
#       [--reasonix-bin <本地 arm64 reasonix 二进制>] [--bmssm-bin <本地 bmssm arm64 二进制>]
#   默认 host=172.26.166.185 user=linaro pass=linaro
#   默认在测试机原有 bmssm 上原地更新；若传 --bmssm-bin 则一并更新 bmssm 二进制。
# 依赖：sshpass、ssh、sqlite3（测试机读取 forward_key）。
#
# 说明：不改 Reasonix 源码；不卸载 picoclaw（仅停止作为 AI Agent 后端）。

set -euo pipefail

HOST="172.26.166.185"
USER="linaro"
PASS="linaro"
REASONIX_ARM64=""
BMSSM_ARM64=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --user) USER="$2"; shift 2 ;;
    --pass) PASS="$2"; shift 2 ;;
    --reasonix-bin) REASONIX_ARM64="$2"; shift 2 ;;
    --bmssm-bin) BMSSM_ARM64="$2"; shift 2 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

SSH=(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 "$USER@$HOST")
SCP=(sshpass -p "$PASS" scp -o StrictHostKeyChecking=no -o ConnectTimeout=15)
run() { "${SSH[@]}" "$@"; }

REASONIX_DIR="/opt/sophon/reasonix"
REASONIX_BIN="$REASONIX_DIR/bin/reasonix"
REASONIX_CFG="/root/.reasonix/config.toml"
BMSSM_YAML="/opt/sophon/bmssm/config/bmssm.yaml"
DR="${REASONIX_DIR%%/}"

echo "==> [1/6] 准备 reasonix 目录"
run "echo '$PASS' | sudo -S -p '' mkdir -p '$REASONIX_DIR/bin' /root/.reasonix"

if [[ -n "$REASONIX_ARM64" ]]; then
  echo "==> [2/6] 上传 reasonix (arm64) 二进制"
  "${SCP[@]}" "$REASONIX_ARM64" "$USER@$HOST":/tmp/reasonix-arm64
  run "echo '$PASS' | sudo -S -p '' mv /tmp/reasonix-arm64 '$REASONIX_BIN' && echo '$PASS' | sudo -S -p '' chmod +x '$REASONIX_BIN'"
else
  echo "==> [2/6] 跳过 reasonix 二进制上传（--reasonix-bin 未指定，沿用现有 $REASONIX_BIN）"
fi

echo "==> [3/6] 读取 bmssm forward_key（Reasonix provider 的透传凭据）"
FORWARD_KEY=$(run "echo '$PASS' | sudo -S -p '' sqlite3 /var/lib/bmssm/bmssm.db 'SELECT forward_key FROM llm_proxy_config WHERE id=1;' 2>/dev/null" | tr -d '\r' | tail -1)
if [[ -z "$FORWARD_KEY" ]]; then
  echo "  警告：未读到 forward_key；Reasonix 将无法认证 llmproxy。" >&2
  exit 1
fi

echo "==> [4/6] 写入 Reasonix 用户配置（provider → 本机 llmproxy，sandbox off）"
cat > "/tmp/reasonix-config.toml.$$" <<CFG
# Reasonix ACP provider config（sophon-tools MYS-170）
# Upstream = 本机 llmproxy（127.0.0.1:18080/v1，OpenAI shim），转发 sophnet DeepSeek-V4-Flash-0731。
# 集中 egress，无嵌套密钥；forward key 经 bmssm systemd 环境注入（DEEPSEEK_API_KEY）。
default_model = "sophnet"

[[providers]]
name           = "sophnet"
kind           = "openai"
base_url       = "http://127.0.0.1:18080/v1"
model          = "DeepSeek-V4-Flash-0731"
api_key_env    = "DEEPSEEK_API_KEY"
reasoning_protocol = "openai"
context_window = 131072

[sandbox]
bash = "off"     # 测试机无 bubblewrap；关闭 bash 沙箱以允许 unconfined shell
CFG
"${SCP[@]}" "/tmp/reasonix-config.toml.$$" "$USER@$HOST":/tmp/reasonix-config.toml >/dev/null
run "echo '$PASS' | sudo -S -p '' cp /tmp/reasonix-config.toml '$REASONIX_CFG'"
run "echo '$PASS' | sudo -S -p '' chmod 600 '$REASONIX_CFG'"
rm -f "/tmp/reasonix-config.toml.$$"

echo "==> [5/6] 配置 bmssm agentproxy + 环境变量，重启 bmssm"
run "echo '$PASS' | sudo -S -p '' mkdir -p /etc/systemd/system/bmssm.service.d"
run "echo '$PASS' | sudo -S -p '' bash -c 'cat > /etc/systemd/system/bmssm.service.d/env-reasonix.conf <<ENVEOF
[Service]
Environment=DEEPSEEK_API_KEY=$FORWARD_KEY
ENVEOF'"
# 幂等注入 agentproxy 段（不存在才追加；不改动已有 agentproxy 配置之外的字段）
run "echo '$PASS' | sudo -S -p '' bash -c '
if grep -q \"^agentproxy:\" \"$BMSSM_YAML\"; then
  echo skip-agentproxy-section
else
  echo -e \"\n# Reasonix ACP 适配器（agentproxy）\nagentproxy:\n  enabled: true\n  listenIP: 0.0.0.0\n  port: 18990\n  binaryPath: $REASONIX_BIN\n  workDir: /home/linaro\n  model: \"\"\n  restartBackoffMax: 30s\" >> \"$BMSSM_YAML\"
fi'"
if [[ -n "$BMSSM_ARM64" ]]; then
  echo "==> [5b] 上传 bmssm (arm64) 二进制"
  "${SCP[@]}" "$BMSSM_ARM64" "$USER@$HOST":/tmp/bmssm-arm64
  run "echo '$PASS' | sudo -S -p '' mv /tmp/bmssm-arm64 /opt/sophon/bmssm/bin/bmssm && echo '$PASS' | sudo -S -p '' chmod +x /opt/sophon/bmssm/bin/bmssm"
fi
run "echo '$PASS' | sudo -S -p '' systemctl daemon-reload && echo '$PASS' | sudo -S -p '' systemctl restart bmssm"

echo "==> [6/6] 验证"
# 等 bmssm 起来 + agentproxy 拉 reasonix acp 握手
for i in $(seq 1 15); do
  INIT_OK=$(run "echo '$PASS' | sudo -S -p '' grep -E 'agentproxy: initialize ok' /var/log/bmssm/bmssm.log 2>/dev/null | tail -1" || true)
  [[ -n "$INIT_OK" ]] && break
  sleep 1
done
echo "  agentproxy 握手: ${INIT_OK:-未检测到（请查看 /var/log/bmssm/bmssm.log）}"
PORT_OK=$(run "ss -tlnp 2>/dev/null | grep 18990 | head -1" || true)
echo "  WS 18990: ${PORT_OK:-未监听}"
echo "==> 完成。浏览器访问 http://\$HOST:8080/resource/web-chat/（sophliteos Agent 页内嵌）即可对话。"
