#!/bin/bash

set -e

echo "build ota_update ..."

rm -rf output 2>/dev/null
mkdir output

# 主脚本（release 产物名为 ota_update.sh，源码文件为 ota.sh）
cp ota.sh output/ota_update.sh
cp ota.sh output/ota.sh
# 附加脚本与 arm64 二进制
cp get_network_info.sh output/ 2>/dev/null || true
cp -r arm64_bin output/ 2>/dev/null || true

ls -la output/
echo "build ota_update done"
