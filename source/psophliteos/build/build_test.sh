#!/bin/sh
# 废弃：旧 tgz 构建流程（build_test），已被统一构建接口替换。
# 请使用仓库根的 `bash release.sh [ARCH] [VERSION]`（M1 规范）或
# `build/build-deb-sophliteos.sh <VERSION> <soc|pcie>` 直接出 deb。保留仅供回溯。
set -e

current_directory=${PWD##*/}

# 检查当前目录是否为"build"
if [ "$current_directory" != "build" ]; then
  echo "错误：该脚本必须在build目录中执行。"
  exit 1
fi

sh version.sh "V2.0.0"
mv release_version.txt ../

cp -r ../frontend/dist ../

cd ..
sh ./scrip/package.sh

cd build

mv ../sophliteos-linux_arm64.tgz ../sophliteos-linux_amd64.tgz  ../release

rm -rf ../dist tmp ../release_version.txt ../sophliteos 