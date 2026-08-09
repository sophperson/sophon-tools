#!/bin/bash
# psocbak 统一构建接口 (M1 规范 v0.1)
# 用法: bash release.sh [ARCH] [VERSION]
#   ARCH:    arm64（默认，binTools 为 aarch64）；amd64 仅打包脚本
#   VERSION: 显式版本号（默认从 socbak/socbak.sh 提取 v1.2.1）
#   env OUTPUT_DIR: 产物目录（默认 <repo>/output/psocbak/）
set -uo pipefail

BUILD_RET=0

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
cd "$SCRIPT_DIR"   # 打包源/产物路径全部以本脚本目录为基准，消除对调用方 cwd 的依赖
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARCH="${1:-arm64}"
VERSION="${2:-$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "$SCRIPT_DIR/socbak/socbak.sh" | head -1)}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/output/psocbak}"

echo "build socbak (arch=$ARCH version=$VERSION) ..."

# 本地中间目录：打包源即 $SCRIPT_DIR/socbak（zip 条目以 socbak/ 为顶层，
# 与现场 `unzip socbak.zip; cd socbak` 的用法一致）。
rm -rf "$SCRIPT_DIR/socbak.zip" 2>/dev/null
rm -rf "$SCRIPT_DIR/output" 2>/dev/null
mkdir -p "$SCRIPT_DIR/output"

if command -v 7z >/dev/null 2>&1; then
	echo "found 7z"
	7z a -mx9 "$SCRIPT_DIR/socbak.zip" "$SCRIPT_DIR/socbak" >/dev/null
	BUILD_RET=$?
elif command -v zip >/dev/null 2>&1; then
	echo "found zip"
	zip -r -9 "$SCRIPT_DIR/socbak.zip" socbak >/dev/null
	BUILD_RET=$?
else
	echo "Unsatisfied build dependencies"
	BUILD_RET=-1
fi

if [ "$BUILD_RET" = "0" ] && [ -s "$SCRIPT_DIR/socbak.zip" ]; then
	# 校验 zip 非空且至少含 1 个条目，防止错误 cwd 下静默产出空包仍被拷贝
	if command -v unzip >/dev/null 2>&1; then
		if ZIP_LIST="$(unzip -Z1 "$SCRIPT_DIR/socbak.zip" 2>/dev/null)"; then
			ZIP_ENTRIES=0
			while IFS= read -r _entry; do ZIP_ENTRIES=$((ZIP_ENTRIES + 1)); done <<EOF
$ZIP_LIST
EOF
			if [ "$ZIP_ENTRIES" -lt 1 ]; then
				echo "ERROR: socbak.zip 为空（条目数 0），打包失败" >&2
				BUILD_RET=1
			else
				echo "socbak.zip ok, entries=$ZIP_ENTRIES"
			fi
		else
			echo "ERROR: socbak.zip 无法解析（unzip 失败），打包失败" >&2
			BUILD_RET=1
		fi
	else
		echo "socbak.zip ok (unzip 不可用，跳过条目校验)"
	fi
else
	echo "ERROR: socbak.zip 缺失或为空，打包失败" >&2
	BUILD_RET=1
fi

if [ "$BUILD_RET" = "0" ]; then
	cp "$SCRIPT_DIR/socbak.zip" "$SCRIPT_DIR/output/"
fi

# 统一接口：汇聚产物到 OUTPUT_DIR
mkdir -p "$OUTPUT_DIR"
if [ "$BUILD_RET" = "0" ]; then
	cp "$SCRIPT_DIR/socbak.zip" "$OUTPUT_DIR/"
fi

exit $BUILD_RET
