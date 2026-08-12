#!/bin/bash
# bmssm .deb 打包：交叉编译 arm64 静态二进制 + 组装 deb 数据树 + dpkg-deb。
# 用法: bash build/build-deb-bmssm.sh [VERSION] [ARCH] [REASONIX_BIN]
#   VERSION      默认 2.1.0（与 build/version.sh 一致）
#   ARCH         默认 arm64（设备）；amd64 用于 PCIE/开发机
#   REASONIX_BIN 可选：reasonix arm64 二进制路径。提供则把 Reasonix 一并嵌入 deb，
#               安装到 /opt/sophon/reasonix/bin/reasonix，并在 bmssm.yaml 里把
#               agentproxy.binaryPath 指向它（出厂即带 AI Agent 后端）。
#               省略则只打 bmssm（Reasonix 需后续单独部署）。
# 产物: release/bmssm_${VERSION}_${ARCH}.deb
set -e

cd "$(dirname "$0")/.."
VERSION="${1:-2.1.0}"
# 版本号不允许进入 sed 替换分隔符；若含 / 则替换为 -（同时保持产物名一致）
VERSION="${VERSION//\//-}"
ARCH="${2:-arm64}"
REASONIX_BIN="${3:-${REASONIX_BIN:-}}"

# 1. 交叉编译静态二进制 + 打包 bmssm.yaml 到 release/
#    arm64 走 musl 静态；amd64 用宿主 gcc 动态链接（开发机用）
if [ "$ARCH" = "arm64" ]; then
  bash build/build-bmssm-arm64.sh "$VERSION"
else
  bash build/build-bmssm.sh "$VERSION"
fi

# 2. 组装 deb 数据树（绝对路径布局，postinst 建运行目录）
DEBROOT=build/deb/bmssm-root
rm -rf "$DEBROOT"
mkdir -p "$DEBROOT/DEBIAN" \
         "$DEBROOT/opt/sophon/bmssm/bin" \
         "$DEBROOT/opt/sophon/bmssm/config" \
         "$DEBROOT/usr/lib/systemd/system"

cp release/bmssm "$DEBROOT/opt/sophon/bmssm/bin/bmssm"
chmod 0755 "$DEBROOT/opt/sophon/bmssm/bin/bmssm"
cp release/bmssm.yaml "$DEBROOT/opt/sophon/bmssm/config/bmssm.yaml"
cp build/bmssm.service "$DEBROOT/usr/lib/systemd/system/bmssm.service"

# 嵌入 Reasonix：若指定了二进制，铺到 /opt/sophon/reasonix/bin/reasonix，
# 并把打包的 bmssm.yaml agentproxy.binaryPath 指向它（一并启用 AI Agent 后端）。
if [ -n "$REASONIX_BIN" ]; then
  if [ ! -f "$REASONIX_BIN" ]; then
    echo "ERROR: REASONIX_BIN 不存在: $REASONIX_BIN" >&2
    exit 1
  fi
  mkdir -p "$DEBROOT/opt/sophon/reasonix/bin"
  cp "$REASONIX_BIN" "$DEBROOT/opt/sophon/reasonix/bin/reasonix"
  chmod 0755 "$DEBROOT/opt/sophon/reasonix/bin/reasonix"
  # bmssm.yaml：启用 agentproxy 并指向内嵌 reasonix
  sed -i \
    -e 's|^  enabled: false.*|  enabled: true|' \
    -e "s|^  binaryPath: \"\".*|  binaryPath: \"/opt/sophon/reasonix/bin/reasonix\"|" \
    "$DEBROOT/opt/sophon/bmssm/config/bmssm.yaml"
  echo "✓ 已嵌入 Reasonix: /opt/sophon/reasonix/bin/reasonix（agentproxy 已启用）"
fi

# 3. DEBIAN 控制文件（Version/Architecture 注入）
#    注: ARCH 未过 dpkg-architecture 映射，当前 arm64/amd64 即 Debian 架构名；
#        未来扩展 armhf/armel 等时需映射。
sed -e "s/@VERSION@/$VERSION/" -e "s/@ARCH@/$ARCH/" \
  build/deb/bmssm.control > "$DEBROOT/DEBIAN/control"
cp build/deb/postinst "$DEBROOT/DEBIAN/postinst"
cp build/deb/prerm    "$DEBROOT/DEBIAN/prerm"
cp build/deb/postrm   "$DEBROOT/DEBIAN/postrm"
cp build/deb/conffiles "$DEBROOT/DEBIAN/conffiles"
chmod 0755 "$DEBROOT/DEBIAN/postinst" "$DEBROOT/DEBIAN/prerm" "$DEBROOT/DEBIAN/postrm"
chmod 0644 "$DEBROOT/DEBIAN/control" "$DEBROOT/DEBIAN/conffiles"

# 4. md5sums（数据文件校验和，路径不含前导 /，对齐 deb policy）
( cd "$DEBROOT" && find . -type f ! -path './DEBIAN/*' -printf '%P\0' | \
  sort -z | xargs -0 md5sum ) > "$DEBROOT/DEBIAN/md5sums"

# 5. 打包
mkdir -p release
OUT="release/bmssm_${VERSION}_${ARCH}.deb"
dpkg-deb --root-owner-group -b "$DEBROOT" "$OUT"
rm -rf "$DEBROOT"

echo
echo "✓ built $OUT"
dpkg-deb -f "$OUT" Package Version Architecture Maintainer
echo "--- contents ---"
dpkg-deb -c "$OUT" | grep -vE '/$'
