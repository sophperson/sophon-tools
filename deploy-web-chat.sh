#!/usr/bin/env bash
# deploy-web-chat.sh — 部署 AI Agent Web Chat 静态客户端到测试机
#
# 两种部署模式：
#
# 模式 A — 独立端口（默认，向后兼容 MYS-149 S4T4）：
#   · web-chat 静态文件 → /opt/sophon/web-chat/
#   · nginx 站点 web-chat 监听 18888（/ 返回 web-chat index.html）
#   · 独立服务，供直接访问 http://<host>:18888/
#
# 模式 B — 内嵌 sophliteos（--embedded，MYS-149 用户需求）：
#   · web-chat 静态文件 → /opt/sophon/sophliteos/dist/resource/web-chat/
#   · 由 sophliteos(8080) 自身托管，访问 http://<host>:8080/resource/web-chat/
#   · 不依赖独立 nginx 服务；配 sophliteos「AI Agent / Agent」页 iframe 内嵌
#     （apply-ai-agent-webchat.sh --embedded）
#
# 开箱即用（MYS-149 S6T6，方案 a+c 组合，两种模式通用）：
#   · 默认从测试机 ~/.picoclaw/.security.yml 读取 pico.settings.token，
#     生成 <部署根>/config.js（window.PICO_WEB_CHAT_CONFIG = { token, wsUrl }）。
#     前端页面加载即自动带上 token 连接，用户零配置即可对话。
#   · config.js 仅存在于部署产物，不入仓库；token 不写进任何仓库文件。
#   · 传 --no-token 可跳过注入（保留 T3 的手动填写模式，向后兼容）。
#
# 用法：
#   bash deploy-web-chat.sh [--host <ssh-host>] [--user <ssh-user>] [--pass <ssh-pass>]
#                           [--embedded] [--no-token]
#   默认：host=172.26.166.185 user=linaro pass=linaro
#   依赖：sshpass、ssh、python3（生成 config.js 时转义 token）；本脚本需与 web-client/ 同处仓库根。
#
# 验证：
#   独立模式:  curl http://<host>:18888/ → 200 index.html
#   内嵌模式:  curl http://<host>:8080/resource/web-chat/ → 200 index.html
#   config.js:  curl http://<host>:<port>/config.js → window.PICO_WEB_CHAT_CONFIG = { ... }

set -euo pipefail

HOST="172.26.166.185"
USER="linaro"
PASS="linaro"
PORT=18888
NO_TOKEN=0
EMBEDDED=0

# 独立模式部署根（模式 A）
WEB_ROOT="/opt/sophon/web-chat"
# 内嵌模式部署根（模式 B）：sophliteos dist 的 resource 子目录，由 sophliteos(8080) 静态托管
SOPH_DIST="/opt/sophon/sophliteos/dist"
EMBED_REL="resource/web-chat"
EMBED_ROOT="${SOPH_DIST}/${EMBED_REL}"

NGINX_SITE="web-chat"
NGINX_AVAILABLE="/etc/nginx/sites-available/${NGINX_SITE}"
NGINX_ENABLED="/etc/nginx/sites-enabled/${NGINX_SITE}"

# 定位 web-client 目录（本脚本位于仓库根，web-client 与其同目录）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEB_CLIENT_DIR="${SCRIPT_DIR}/web-client"
if [[ ! -f "${WEB_CLIENT_DIR}/index.html" ]]; then
  echo "错误：未找到 ${WEB_CLIENT_DIR}/index.html，请确保在仓库根运行本脚本" >&2
  exit 1
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --user) USER="$2"; shift 2 ;;
    --pass) PASS="$2"; shift 2 ;;
    --no-token) NO_TOKEN=1; shift ;;
    --embedded) EMBEDDED=1; shift ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done

if [[ "$EMBEDDED" -eq 1 ]]; then
  DEPLOY_ROOT="$EMBED_ROOT"
  MODE_LABEL="内嵌 sophliteos（8080/resource/web-chat）"
else
  DEPLOY_ROOT="$WEB_ROOT"
  MODE_LABEL="独立端口 $PORT（nginx 静态托管）"
fi

SSH=(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 "$USER@$HOST")
SCP=(sshpass -p "$PASS" scp -o StrictHostKeyChecking=no -o ConnectTimeout=15)

run_remote() {
  "${SSH[@]}" "$@"
}

echo "==> 部署模式：${MODE_LABEL}"
echo "==> [1/5] 准备远程目录 ${DEPLOY_ROOT}"
if [[ "$EMBEDDED" -eq 1 ]]; then
  # sophliteos dist 目录可能由 root 属主，需 sudo 创建子目录并放开写权限
  run_remote "
    echo '$PASS' | sudo -S -p '' mkdir -p '$DEPLOY_ROOT'
    echo '$PASS' | sudo -S -p '' chown -R ${USER}:${USER} '$DEPLOY_ROOT'
  "
else
  run_remote "echo '$PASS' | sudo -S -p '' mkdir -p '$DEPLOY_ROOT' && echo '$PASS' | sudo -S -p '' chown ${USER}:${USER} '$DEPLOY_ROOT'"
fi

echo "==> [2/5] 上传 web-client 静态文件"
tar -C "$WEB_CLIENT_DIR" -czf - . | run_remote "tar -xzf - -C '$DEPLOY_ROOT'"

echo "==> [3/5] 生成 config.js（开箱即用 token 注入）"
CONFIG_JS="/tmp/web-chat-config.js.$$"
if [[ "$NO_TOKEN" -eq 1 ]]; then
  echo "  已指定 --no-token，跳过 token 注入（手动填写模式）。"
  # 保留空 config.js（避免 404，前端按无注入处理）
  echo "window.PICO_WEB_CHAT_CONFIG = {};" > "$CONFIG_JS"
else
  # 远程读取 token：定位 .security.yml 中 pico 频道段的 token。
  # 逐候选路径尝试远程 cat，输出经管道交 python3 精确解析 pico 段
  # （避免误取其他频道同名 token，也规避远端引号转义）。
  PY_EXTRACT="/tmp/web-chat-extract.$$.py"
  cat > "$PY_EXTRACT" <<'PYEOF'
import sys, re
token = ""
in_pico = False
for line in sys.stdin:
    s = line.rstrip("\n")
    if re.match(r"^\s*pico:\s*$", s):
        in_pico = True
        continue
    if in_pico:
        m = re.match(r"^(\s*)([a-zA-Z0-9_-]+):\s*$", s)
        if m and len(m.group(1)) == 0:
            # 顶层键（下一个频道或其他顶层项）：离开 pico 段
            break
        m2 = re.match(r"^\s*token\s*:\s*(.+?)\s*$", s)
        if m2:
            token = m2.group(1).strip().strip("\"'")
            break
print(token, end="")
PYEOF
  TOKEN=$(run_remote '
    for f in "$HOME/.picoclaw/.security.yml" /home/*/.picoclaw/.security.yml /opt/sophon/*/.security.yml; do
      [ -f "$f" ] && { cat "$f"; exit 0; }
    done
    exit 1
  ' | python3 "$PY_EXTRACT" || true)
  rm -f "$PY_EXTRACT"
  if [[ -z "$TOKEN" ]]; then
    echo "  警告：未从测试机读取到 pico token（.security.yml 未找到或格式不符），跳过注入。" >&2
    echo "  如确需注入，请检查 ~/.picoclaw/.security.yml 的 pico.settings.token，或改用 --no-token 明确手动模式。" >&2
    echo "window.PICO_WEB_CHAT_CONFIG = {};" > "$CONFIG_JS"
  else
    # 用 python3 生成合法 JS 字面量（token 可能含特殊字符）
    PICO_TOKEN="$TOKEN" PICO_HOST="$HOST" python3 - > "$CONFIG_JS" <<'PYEOF'
import json, os
host = os.environ["PICO_HOST"]
ws_url = f"ws://{host}:18790/pico/ws"
print(f"window.PICO_WEB_CHAT_CONFIG = {json.dumps({'token': os.environ['PICO_TOKEN'], 'wsUrl': ws_url}, ensure_ascii=False)};")
PYEOF
    echo "  已读取 pico token，生成 config.js（ws 地址自动使用当前主机 ${HOST}）"
  fi
fi
"${SCP[@]}" "$CONFIG_JS" "$USER@$HOST":/tmp/web-chat-config.js >/dev/null
run_remote "mv /tmp/web-chat-config.js '$DEPLOY_ROOT/config.js' && chown ${USER}:${USER} '$DEPLOY_ROOT/config.js'"
rm -f "$CONFIG_JS"

if [[ "$EMBEDDED" -eq 1 ]]; then
  # 内嵌模式：不配置独立 nginx 18888，由 sophliteos 托管
  echo "==> [4/5] 内嵌模式：跳过 nginx 独立站点（由 sophliteos 托管 resource/web-chat）"
else
  echo "==> [4/5] 配置 nginx 站点（监听 $PORT）"
  cat > /tmp/web-chat-nginx.conf <<EOF
# AI Agent Web Chat 静态站点（模式 A：独立端口托管，与 picoclaw-launcher 18800 无冲突）
server {
	listen ${PORT} default_server;

	root ${WEB_ROOT};
	index index.html;

	location / {
		try_files \$uri \$uri/ /index.html;
	}

	# config.js 含敏感 token：禁止浏览器/代理缓存，避免落盘后长期暴露
	location = /config.js {
		default_type application/javascript;
		add_header Cache-Control "no-store, no-cache, must-revalidate";
		add_header Pragma "no-cache";
	}

	location ~* \\.(js|css|png|jpg|jpeg|gif|svg|ico|woff2?)$ {
		expires 7d;
		add_header Cache-Control "public";
	}
}
EOF
  "${SCP[@]}" /tmp/web-chat-nginx.conf "$USER@$HOST":/tmp/web-chat-nginx.conf >/dev/null
  run_remote "
    echo '$PASS' | sudo -S -p '' cp /tmp/web-chat-nginx.conf $NGINX_AVAILABLE
    echo '$PASS' | sudo -S -p '' ln -sf $NGINX_AVAILABLE $NGINX_ENABLED
    echo '$PASS' | sudo -S -p '' nginx -t
    echo '$PASS' | sudo -S -p '' systemctl reload nginx
    echo '$PASS' | sudo -S -p '' systemctl enable nginx >/dev/null 2>&1 || true
  "
  rm -f /tmp/web-chat-nginx.conf
fi

echo "==> [5/5] 验证"
if [[ "$EMBEDDED" -eq 1 ]]; then
  run_remote "
    code=\$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/resource/web-chat/)
    echo \"内嵌 web-chat HTTP \$code (期望 200)\"
    title=\$(curl -s http://127.0.0.1:8080/resource/web-chat/ | grep -o '<title>[^<]*</title>')
    echo \"\$title\"
    if curl -s http://127.0.0.1:8080/resource/web-chat/config.js | grep -q '\"token\": \"[^\" ]'; then
      echo 'config.js 已注入 ✓（token 仅部署产物可见）'
    else
      echo 'config.js 为空或未注入（--no-token / 未读到 token，回退手动填写模式）'
    fi
  "
  echo "==> 完成：浏览器访问 http://${HOST}:8080/resource/web-chat/ 即可对话（内嵌 sophliteos，开箱即用）。"
  echo "    再执行 apply-ai-agent-webchat.sh --embedded 让 sophliteos「AI Agent / Agent」页 iframe 指向该内嵌页面。"
else
  run_remote "
    code=\$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:${PORT}/)
    echo \"web-chat HTTP \$code (期望 200)\"
    title=\$(curl -s http://127.0.0.1:${PORT}/ | grep -o '<title>[^<]*</title>')
    echo \"\$title\"
    if curl -s http://127.0.0.1:${PORT}/config.js | grep -q '\"token\": \"[^\" ]'; then
      echo 'config.js 已注入 ✓（token 仅部署产物可见）'
    else
      echo 'config.js 为空或未注入（--no-token / 未读到 token，回退手动填写模式）'
    fi
  "
  echo "==> 完成：浏览器访问 http://${HOST}:${PORT}/ 即可对话（开箱即用，无需配置）。"
fi
