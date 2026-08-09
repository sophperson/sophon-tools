#!/bin/bash

# 官方独立构建脚本（统一构建走 release.sh）。cd 到脚本目录，
# 避免从仓库根运行 build.sh 时 `rm -rf target` 误删其他目录（MYS-58 S-3）。
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

PATH=${PATH}:~/.cargo/bin/
CROSS=$(which cross)

rm -rf "$SCRIPT_DIR/target"
cargo install cross cargo-bloat
echo "$(git describe --tags --abbrev=0)-$(git rev-parse HEAD)-$(date -u "+%Y%m%d_%H%M%S")" > .git_version
${CROSS} build --target aarch64-unknown-linux-musl --release
upx -9 --best --nrv2b --no-color target/aarch64-unknown-linux-musl/release/bm_set_ip
