#!/bin/bash
# pbmsec 统一构建接口 (M1 规范 v0.1)
# 用法: bash release.sh [ARCH] [VERSION]
#   ARCH:    all（默认，deb 为 Architecture: all 双架构合并包）
#   VERSION: 显式版本号（默认 1.6.4）
#   env OUTPUT_DIR: 产物目录（默认 <repo>/output/pbmsec/）
# 依赖: 先构建 psocbak（自动同步 socbak.zip，缺失时用入库旧包）
set -uo pipefail

BUILD_RET=0

echo "build bmsec ..."

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARCH="${1:-all}"
BMSEC_PACKAGE_VERSION="${2:-1.6.4}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/output/pbmsec}"

export CMD_PANDOC=$(command -v pandoc)
export CMD_DPKG_DEB=$(command -v dpkg-deb)

rm -rf bmsec*.deb 2>/dev/null
rm -rf *.deb* 2>/dev/null
rm -rf output 2>/dev/null
rm -rf ./*.html
mkdir output

# Sync socbak.zip from sibling psocbak project.
# Run psocbak/release.sh first if a fresh build is needed; otherwise the
# prebuilt socbak.zip is reused. The zip is shipped inside bmsec/binTools/.
SOCBAK_SRC="$(dirname "$(pwd)")/psocbak/socbak.zip"
SOCBAK_DST="deb/opt/sophon/bmsec/binTools/socbak.zip"
if [ -f "$SOCBAK_SRC" ]; then
	echo "sync socbak.zip from $SOCBAK_SRC"
	cp "$SOCBAK_SRC" "$SOCBAK_DST"
else
	if [ ! -f "$SOCBAK_DST" ]; then
		echo "ERROR: socbak.zip not found at $SOCBAK_SRC or $SOCBAK_DST"
		echo "       run bash release.sh in the psocbak project first, or place socbak.zip manually"
		exit 1
	fi
	echo "WARN: $SOCBAK_SRC not found, reuse existing $SOCBAK_DST"
fi

if [ -f "$CMD_PANDOC" ] && [ -f "$CMD_DPKG_DEB" ]; then
	echo "found $CMD_PANDOC and $CMD_DPKG_DEB"
	pushd doc
		for file in *.md; do
			if [ -f "$file" ]; then
				echo "Converting $file to HTML ${file%.md}.html ..."
				$CMD_PANDOC "$file" --self-contained -c bootstrap.min.css --metadata title=${file%.md} -o "${file%.md}.html"
			fi
		done
		mkdir -p deb/opt/sophon/bmsec/doc/
		rm -rf deb/opt/sophon/bmsec/doc/*
		cp *.html deb/opt/sophon/bmsec/doc/
		rm -rf bmsec.1
		echo "Converting man Doc file ..."
		cat *.md | $CMD_PANDOC -s --self-contained -c bootstrap.min.css -t man -o bmsec.1
		mkdir -p deb/usr/share/man/man1/
		rm -rf deb/usr/share/man/man1/*
		cp bmsec.1 deb/usr/share/man/man1/
	popd
	rm -rf deb/opt/sophon/bmsec/configs/subNANInfo
	BMSEC_VERSION=${BMSEC_PACKAGE_VERSION}
	cp deb/DEBIAN/control ./control.bak
	sed -i "s/BMSEC_VERSION/$BMSEC_VERSION/" deb/DEBIAN/control
	echo "deb build version: ${BMSEC_VERSION}"
	$CMD_DPKG_DEB -b deb bmsec_v$BMSEC_VERSION.deb
	mv ./control.bak deb/DEBIAN/control
	if [ -f "bmsec_v$BMSEC_VERSION.deb" ]; then
		BUILD_RET=0
	else
		BUILD_RET=-1
	fi
else
	echo "Unsatisfied build dependencies"
	BUILD_RET=-1
fi
cp *.deb output/

# 统一接口：汇聚产物到 OUTPUT_DIR
mkdir -p "$OUTPUT_DIR"
cp *.deb "$OUTPUT_DIR/"

exit $BUILD_RET
