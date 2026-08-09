#!/bin/bash
# pbmsec 统一构建接口 (M1 规范 v0.1)
# 用法: bash release.sh [ARCH] [VERSION]
#   ARCH:    all（默认，deb 为 Architecture: all 双架构合并包）
#   VERSION: 显式版本号（默认 1.6.4）
#   env OUTPUT_DIR: 产物目录（默认 <repo>/output/pbmsec/）
# 依赖: socbak.zip（打进 binTools/）。获取顺序: ① ../psocbak/output/ 的构建产物
#       → ② 现场从 ../psocbak/socbak/ 打包 → ③ 本地已入库 socbak.zip（无则报错）。
#       build-all.sh 已声明 psocbak 先于 pbmsec 构建（DEPENDS）。
set -uo pipefail

BUILD_RET=0

echo "build bmsec ..."

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
cd "$SCRIPT_DIR"   # 相对路径全部以本脚本目录为基准，与其余子项目对齐
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARCH="${1:-all}"
BMSEC_PACKAGE_VERSION="${2:-1.6.4}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/output/pbmsec}"

export CMD_PANDOC=$(command -v pandoc)
export CMD_DPKG_DEB=$(command -v dpkg-deb)

rm -rf bmsec*.deb 2>/dev/null
rm -rf ./*.html
rm -rf ./*.1
rm -rf deb/opt/sophon/bmsec/doc deb/usr/share/man/man1 2>/dev/null

# Sync socbak.zip from sibling psocbak project.
# 优先复用 psocbak 的构建产物（output/socbak.zip 或项目根 socbak.zip）；
# 缺失时现场从 ../psocbak/socbak/ 目录打包（与 psocbak/release.sh 同一压缩方式）；
# 兜底复用本地已入库 socbak.zip，再不行则报错退出。
SOCBAK_DST="$SCRIPT_DIR/deb/opt/sophon/bmsec/binTools/socbak.zip"
ensure_socbak() {
  local src=""
  for candidate in \
    "$SCRIPT_DIR/../psocbak/output/socbak.zip" \
    "$SCRIPT_DIR/../psocbak/socbak.zip"; do
    if [ -f "$candidate" ]; then
      src="$candidate"
      break
    fi
  done

  if [ -n "$src" ]; then
    echo "sync socbak.zip from $src"
    cp "$src" "$SOCBAK_DST"
    return 0
  fi

  # 现场打包: psocbak 源码目录入库（socbak.zip 本身被 gitignore），
  # 与 psocbak/release.sh 的打包方式一致（7z 优先, 退 zip）。
  local socbak_dir="$SCRIPT_DIR/../psocbak/socbak"
  if [ -d "$socbak_dir" ]; then
    echo "socbak.zip not prebuilt, packaging from $socbak_dir ..."
    if command -v 7z >/dev/null 2>&1; then
      (cd "$SCRIPT_DIR/../psocbak" && 7z a -mx9 "$SOCBAK_DST" socbak >/dev/null) \
        && echo "packed socbak.zip with 7z" && return 0
    fi
    if command -v zip >/dev/null 2>&1; then
      (cd "$SCRIPT_DIR/../psocbak" && zip -r -9 "$SOCBAK_DST" socbak >/dev/null) \
        && echo "packed socbak.zip with zip" && return 0
    fi
    echo "ERROR: 需要 7z 或 zip 来现场打包 socbak.zip (psocbak 未预构建)"
    return 1
  fi

  if [ -f "$SOCBAK_DST" ]; then
    echo "WARN: socbak.zip not found in psocbak, reuse existing $SOCBAK_DST"
    return 0
  fi

  echo "ERROR: socbak.zip not found at $SOCBAK_DST (psocbak 未构建且无法现场打包)"
  echo "       run bash release.sh in the psocbak project first, or place socbak.zip manually"
  return 1
}

if ! ensure_socbak; then
  exit 1
fi

if [ -f "$CMD_PANDOC" ] && [ -f "$CMD_DPKG_DEB" ]; then
  echo "found $CMD_PANDOC and $CMD_DPKG_DEB"
  pushd doc
    mkdir -p "$SCRIPT_DIR/deb/opt/sophon/bmsec/doc/"
    for file in *.md; do
      if [ -f "$file" ]; then
        echo "Converting $file to HTML ${file%.md}.html ..."
        "$CMD_PANDOC" "$file" --self-contained -c bootstrap.min.css --metadata title="${file%.md}" -o "$SCRIPT_DIR/deb/opt/sophon/bmsec/doc/${file%.md}.html" || { echo "ERROR: pandoc 转换 $file 失败" >&2; BUILD_RET=1; }
      fi
    done
    echo "Converting man Doc file ..."
    mkdir -p "$SCRIPT_DIR/deb/usr/share/man/man1/"
    "$CMD_PANDOC" -s --self-contained -c bootstrap.min.css -t man *.md -o "$SCRIPT_DIR/deb/usr/share/man/man1/bmsec.1" || { echo "ERROR: pandoc 生成 man 页失败" >&2; BUILD_RET=1; }
  popd
  rm -rf deb/opt/sophon/bmsec/configs/subNANInfo
  BMSEC_VERSION=${BMSEC_PACKAGE_VERSION}
  # sed 只替换第一处 BMSEC_VERSION（Version 字段），避免将来 Description 等再出现同名
  # 占位符时被误替换；版本号含 / 时先转义防 sed 破坏。
  VERSION_SAFE="$(printf '%s' "$BMSEC_VERSION" | sed 's|/|\\/|g')"
  # -p 保留属主，容器内 root 构建后 mv 回来时 control 不变成 root 属主
  cp -p deb/DEBIAN/control ./control.bak
  if ! sed -i "0,/BMSEC_VERSION/s/BMSEC_VERSION/$VERSION_SAFE/" deb/DEBIAN/control; then
    echo "ERROR: 写入版本号到 control 失败" >&2
    BUILD_RET=1
  fi
  echo "deb build version: ${BMSEC_VERSION}"
  if [ "$BUILD_RET" = "0" ]; then
    "$CMD_DPKG_DEB" -b deb "bmsec_v$BMSEC_VERSION.deb" || BUILD_RET=1
  fi
  mv ./control.bak deb/DEBIAN/control
  if [ "$BUILD_RET" = "0" ] && [ -f "bmsec_v$BMSEC_VERSION.deb" ]; then
    BUILD_RET=0
  else
    BUILD_RET=1
  fi
else
  echo "Unsatisfied build dependencies"
  BUILD_RET=1
fi

# 统一接口：汇聚产物到 OUTPUT_DIR（构建产物与输出目录合并，不重复拷贝）
mkdir -p "$OUTPUT_DIR"
if ls ./*.deb >/dev/null 2>&1; then
  cp ./*.deb "$OUTPUT_DIR/"
fi

exit $BUILD_RET
