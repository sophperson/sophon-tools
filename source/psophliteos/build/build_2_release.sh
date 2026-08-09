#!/bin/sh
# 废弃：旧 docker-node16 + tgz 构建流程，已被统一构建接口替换。
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

docker run --rm -i --name node-build -v `pwd`/../frontend/:/home/node node:16 sh -c 'cd /home/node && yarn && yarn build'
cp -r ../frontend/dist ../

cd ..
sh ./scrip/package.sh

cd build
mkdir -p tmp 
tar -xzf ../sophliteos-linux_arm64.tgz -C tmp 
bash package-deb.sh soc

rm -rf tmp/*
tar -xzf ../sophliteos-linux_arm64.tgz -C tmp
bash package-deb-sdk.sh soc

rm -rf tmp/*
tar -xzf ../sophliteos-linux_amd64.tgz -C tmp
bash package-deb.sh pcie

rm -rf tmp/*
tar -xzf ../sophliteos-linux_amd64.tgz -C tmp
bash package-deb-sdk.sh pcie

mv sophliteos_soc_2.0.0.deb sophliteos_pcie_2.0.0.deb sophliteos_soc_2.0.0_sdk.deb sophliteos_pcie_2.0.0_sdk.deb ../sophliteos-linux_arm64.tgz ../sophliteos-linux_amd64.tgz  ../release

rm -rf ../dist tmp ../release_version.txt ../sophliteos 