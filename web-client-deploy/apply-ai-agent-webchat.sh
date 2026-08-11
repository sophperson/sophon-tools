#!/usr/bin/env bash
# apply-ai-agent-webchat.sh — sophliteos「AI Agent / Agent」页接入 AI Agent Web Chat（MYS-149）
#
# 两种接入模式：
#
# 模式 A — 独立端口（默认，向后兼容 MYS-149 S5T5）：
#   · 修改 sophliteos 前端探测端口映射，把返回的 launcher 端口 18800 映射为 web-chat 端口 18888。
#   · sophliteos 后端 /api/device/ai-agent/port 固定返回 18800（二进制，无配置项可改）；
#     8080 由 sophliteos 自监听（不经 nginx），无法用部署层重写该接口响应。
#   · 修改 Agent 页探测函数（index.0fee7070.js 的 m()）即可让 iframe src 与「端口 xxx」标签
#     都指向 18888，与独立部署的 web-chat（nginx 18888）一致。
#
# 模式 B — 内嵌 sophliteos（--embedded，MYS-149 用户需求）：
#   · 直接改 Agent 页组件（index.c40a47b0.js）的 iframe src 组装逻辑，
#     指向 http://<host>:8080/resource/web-chat/（web-chat 由 sophliteos 自身托管）。
#   · 不再依赖独立 18888 nginx 服务；sophliteos「AI Agent / Agent」页即内嵌聊天界面。
#
# 非侵入性：不改 sophliteos 二进制/后端，不动 launcher(18800)/gateway(18790)。
# launcher 管理面板仍通过 http://<host>:18800/ 直接访问。
#
# 幂等：已含对应标记则跳过；应用前备份 .orig 与时间戳副本。
#
# 用法：
#   bash apply-ai-agent-webchat.sh [--host <ssh-host>] [--user <ssh-user>] [--pass <ssh-pass>] [--embedded]
#   默认：host=172.26.166.185 user=linaro pass=linaro
#   依赖：sshpass、ssh、python3（本地生成补丁）
#
# 验证：
#   模式 A: 浏览器登录 sophliteos → AI Agent → Agent，iframe 显示 web-chat，「端口 18888」
#   模式 B: 同上，iframe src = http://<host>:8080/resource/web-chat/，端口标签仍显示探测值
#
# 还原：
#   ssh linaro@<host> 'cp /opt/sophon/sophliteos/dist/assets/index.<chunk>.js.orig \
#       /opt/sophon/sophliteos/dist/assets/index.<chunk>.js'   # .orig 属主 linaro，可直接覆盖

set -euo pipefail

HOST="172.26.166.185"
USER="linaro"
PASS="linaro"
EMBEDDED=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --user) USER="$2"; shift 2 ;;
    --pass) PASS="$2"; shift 2 ;;
    --embedded) EMBEDDED=1; shift ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done

ASSETS_DIR="/opt/sophon/sophliteos/dist/assets"
LOCAL_WORK="/tmp/apply-ai-agent-webchat.$$"

SSH_ARGS=(-o StrictHostKeyChecking=no -o ConnectTimeout=15)
run_remote() {
  sshpass -p "$PASS" ssh "${SSH_ARGS[@]}" "$USER@$HOST" "$@"
}

if [[ "$EMBEDDED" -eq 1 ]]; then
  MODE_LABEL="内嵌 sophliteos（iframe → :8080/resource/web-chat/）"
  # 模式 B 目标：Agent 页组件 JS（含 iframe src 组装逻辑）
  DEFAULT_TARGET="index.c40a47b0.js"
  # 标记：iframe src 已指向内嵌路径
  MARKER="8080/resource/web-chat/"
else
  MODE_LABEL="独立端口（iframe → :18888/，探测映射 18800→18888）"
  # 模式 A 目标：Agent 页探测函数 JS（含端口映射）
  DEFAULT_TARGET="index.0fee7070.js"
  MARKER="t.port===18800?18888:t.port"
fi

echo "==> 接入模式：${MODE_LABEL}"
echo "==> [1/4] 定位 sophliteos 前端目标 JS"
# 优先精确文件名；sophliteos 升级后 hash 可能变化，按内容定位
if run_remote "test -f $ASSETS_DIR/$DEFAULT_TARGET"; then
  TARGET="$ASSETS_DIR/$DEFAULT_TARGET"
else
  if [[ "$EMBEDDED" -eq 1 ]]; then
    # 内嵌模式：定位含 iframe src 组装特征（location.hostname} 的 Agent 页组件
    TARGET=$(run_remote "grep -l 'location.hostname}:' $ASSETS_DIR/*.js 2>/dev/null | head -1" | tr -d '\r')
  else
    TARGET=$(run_remote "grep -l 'device/ai-agent/port' $ASSETS_DIR/*.js 2>/dev/null | head -1" | tr -d '\r')
  fi
  if [[ -z "$TARGET" ]]; then
    echo "错误：未找到目标前端 JS（模式 $([ "$EMBEDDED" -eq 1 ] && echo 内嵌 || echo 独立)）" >&2
    exit 1
  fi
  echo "精确文件名不存在，已按内容定位：$TARGET" >&2
fi
echo "目标文件：$TARGET"

echo "==> [2/4] 幂等检查：是否已含标记"
if run_remote "grep -qF '$MARKER' $TARGET"; then
  echo "已包含标记（已打过补丁），无需重复应用。"
  echo "如需强制重新应用，请先还原 .orig。"
  exit 0
fi

echo "==> [3/4] 备份并应用补丁"
mkdir -p "$LOCAL_WORK"
# 下载原文件到本地
sshpass -p "$PASS" scp "${SSH_ARGS[@]}" "$USER@$HOST:$TARGET" "$LOCAL_WORK/original.js" >/dev/null
# 本地生成补丁
LOCAL_WORK="$LOCAL_WORK" EMBEDDED="$EMBEDDED" python3 - <<'PYEOF'
import os, sys
work = os.environ["LOCAL_WORK"]
embedded = os.environ["EMBEDDED"] == "1"
data = open(f"{work}/original.js", encoding='utf-8').read()

if embedded:
    # 模式 B（内嵌精简版）：去掉「AI Agent + 端口标签 + 重新探测」Card 的 title/extra 插槽，
    # 只保留 default 插槽（iframe）。iframe 固定指向 sophliteos 内嵌路径。
    import re
    d_idx = data.find('default:e(()=>[c.value')
    if d_idx == -1:
        print('错误：未找到 default 插槽，可能版式已变，请人工检查', file=sys.stderr)
        sys.exit(1)
    depth = 0; i = d_idx
    while i < len(data):
        c = data[i]
        if c in '([{': depth += 1
        elif c in ')]}': depth -= 1
        if depth == 0: break
        i += 1
    default_slot = data[d_idx:i+1]
    t_idx = data.find('{title:e(()=>')
    if t_idx == -1:
        print('错误：未找到 title 插槽，可能版式已变，请人工检查', file=sys.stderr)
        sys.exit(1)
    prefix = data[:t_idx]  # 以 ',' 结尾（o(u(g),{bordered:!1},）
    patched = prefix + '{' + default_slot + data[i+1:]
    # 内嵌路径：iframe src 固定指向 sophliteos 托管的 resource/web-chat
    patched = patched.replace('`http://${window.location.hostname}:${n}/`',
                              '`http://${window.location.hostname}:8080/resource/web-chat/`')
    # 紧凑：减小 iframe 高度（去掉顶部 Card title/extra 后留白更少）
    patched = patched.replace('calc(100vh - 260px)', 'calc(100vh - 140px)')
else:
    # 模式 A：探测端口映射 18800 → 18888
    old = 'return t&&typeof t=="object"&&typeof t.port=="number"?t.port:null'
    new = 'return t&&typeof t=="object"&&typeof t.port=="number"?(t.port===18800?18888:t.port):null'
    if old not in data:
        print('错误：未找到精确替换片段，可能版式已变，请人工检查', file=sys.stderr)
        sys.exit(1)
    patched = data.replace(old, new, 1)
open(f"{work}/patched.js", 'w', encoding='utf-8').write(patched)
print(f'本地补丁生成完成（{len(data)} -> {len(patched)} 字节）')
PYEOF
# 远程备份：目标文件可能为 root 属主（sophliteos 安装产物），用 sudo 统一处理
run_remote "
  echo '$PASS' | sudo -S -p '' rm -f '$TARGET.orig' '$TARGET.bak-pre-apply'
  echo '$PASS' | sudo -S -p '' cp '$TARGET' '$TARGET.orig'
  echo '$PASS' | sudo -S -p '' cp '$TARGET' '$TARGET.bak-pre-apply'
"
# 上传并替换（目标为 root 属主时用 sudo 覆盖，随后 chown 回 linaro 便于后续维护）
sshpass -p "$PASS" scp "${SSH_ARGS[@]}" "$LOCAL_WORK/patched.js" "$USER@$HOST:/tmp/apply-ai-agent-webchat.patched.js" >/dev/null
run_remote "
  echo '$PASS' | sudo -S -p '' cp /tmp/apply-ai-agent-webchat.patched.js '$TARGET'
  echo '$PASS' | sudo -S -p '' chown ${USER}:${USER} '$TARGET' 2>/dev/null || true
  rm -f /tmp/apply-ai-agent-webchat.patched.js
  echo '已替换'
"
rm -rf "$LOCAL_WORK"

echo "==> [4/4] 验证"
run_remote "
  echo -n '后端探测接口（保持 18800，未改动）：'
  curl -s -m 5 http://127.0.0.1:8080/api/device/ai-agent/port
  echo
  echo -n '前端补丁标记：'
  if curl -s -m 5 http://127.0.0.1:8080/assets/\$(basename '$TARGET') | grep -qF '$MARKER'; then
    echo '已生效 ✓'
  else
    echo '未生效 ✗'
    exit 1
  fi
"

echo "==> 完成。浏览器访问 http://${HOST}:8080/ 登录 sophliteos → AI Agent → Agent 验证。"
echo "    若显示旧内容，请清浏览器缓存后硬刷新（该 chunk 按 URL 缓存）。"
echo "    还原：ssh $USER@$HOST 'cp $TARGET.orig $TARGET'"
