#!/bin/bash
# pautotelecomm 统一构建接口 (M1 规范 v0.1)
# 用法: bash release.sh [ARCH] [VERSION]
#   ARCH:    arm64（默认，设备 SE5/7/9）
#   VERSION: 显式版本号（默认 1.2.8）
#   env OUTPUT_DIR: 产物目录（默认 <repo>/output/pautotelecomm/）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARCH="${1:-arm64}"
VERSION="${2:-1.2.8}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/output/pautotelecomm}"

echo "==> pautotelecomm build arch=$ARCH version=$VERSION"
rm -rf output
mkdir -p output

cat <<'EOF' > output/autotelecomm_install_${VERSION}.sh
#!/bin/bash

if [ "$(id -u)" != "0" ]; then
    echo "need root run"
    exit 1
fi

TMP_DIR=$(mktemp -d)
trap "rm -rf $TMP_DIR" EXIT

offset=$(grep -an "__ARCHIVE_BELOW__" "$0" | tail -n1 | cut -d: -f1)
((offset++))
tail -n +$offset "$0" > "$TMP_DIR/packages.tgz"
tar -xavf "$TMP_DIR/packages.tgz" -C "$TMP_DIR" || exit

systemctl daemon-reload
systemctl stop autotelecomm
systemctl stop ec20

echo "[install rootfs] start ..."
pushd "${TMP_DIR}/rootfs" || exit
cp -r ./* / || exit
popd || exit
sync

echo "[install kernel mod] start ..."
pushd "${TMP_DIR}/kernel" || exit
bash install.sh || exit
popd || exit
sync

if [[ "$(python3 -m pip list | grep pyserial | wc -l)" == "0" ]]; then
    echo "not find pyserial by python, need install ..."
    python3 -m pip install -i https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple pyserial
fi

systemctl daemon-reload
systemctl stop lteModemManager
systemctl disable lteModemManager
sync

echo "[install] success, please restart this device"
exit 0
__ARCHIVE_BELOW__
EOF

tar -caf output/packages.tgz rootfs kernel

cat output/packages.tgz >> output/autotelecomm_install_${VERSION}.sh

chmod +x output/autotelecomm_install_${VERSION}.sh

mkdir -p "$OUTPUT_DIR"
cp output/autotelecomm_install_${VERSION}.sh "$OUTPUT_DIR/"
echo "==> pautotelecomm 完成, 产物: $OUTPUT_DIR"
ls -la "$OUTPUT_DIR"
