#!/bin/bash
###############################################
############zetao.zhang@sophgo.com#############
###############################################

# socbak v1.2.x all-in-one: 算力板上 socbak.sh SOC_BAK_ALL_IN_ONE=tftp
# 直接在算力板上完成分区镜像备份 + tftp 刷机包打包，主控板不再做包。
# socbak.zip 内置于 bmsec 的 binTools/，可独立替换升级：
#   1. 从 https://github.com/sophgo/sophon-tools/releases 下载最新 socbak.zip
#   2. 替换 /opt/sophon/bmsec/binTools/socbak.zip 即可，无需重装 bmsec
SOCBAK_NFS_MIN_AVAIL_MB=3750

nfsConfig_cleanup() {
    local target="${userInputSubId:-}"
    if [[ "$target" =~ ^[0-9]+$ ]]; then
        ${seNCtrl_PWD}/bmsec run $target "sudo umount /socrepack" 2>/dev/null
    fi
    sudo rm -rf /etc/exports.d/bmsecNfsSysBak.exports
    sudo exportfs -ra
    sudo systemctl restart nfs-server
}

systemBakPack_cleanup() {
    echo -e "\nReceived a kill signal. Cleaning up..."
    nfsConfig_cleanup
    exit 0
}
trap systemBakPack_cleanup SIGTERM SIGINT

function nfsShareBak(){
    id="$1"
    seNCtrl_NFS_PATH_LOCAL="$2"
    seNCtrl_NFS_PATH_REMOTE="$3"
    echo "INFO: socbak.zip comes from bmsec/binTools/. To update socbak, download the latest from https://github.com/sophgo/sophon-tools/releases/ and replace /opt/sophon/bmsec/binTools/socbak.zip"
    sudo mkdir -p ${seNCtrl_NFS_PATH_LOCAL}
    sudo chmod 777 ${seNCtrl_NFS_PATH_LOCAL}
    sudo mkdir -p /etc/exports.d/
    sudo cp ${seNCtrl_PWD}/configs/bmsecNfsSysBak.exports /etc/exports.d/
    sudo cp ${seNCtrl_PWD}/binTools/socbak.zip ${seNCtrl_NFS_PATH_LOCAL}
    sudo sed -i "s|172.16|$seNCtrl_SUB_IP_HALF|g" /etc/exports.d/bmsecNfsSysBak.exports
    sudo sed -i "s|/data/bmsecNfsShare|$seNCtrl_NFS_PATH_LOCAL|g" /etc/exports.d/bmsecNfsSysBak.exports
    ${seNCtrl_PWD}/bmsec run $id "for mount_point in \$(mount | grep nfs | awk '{print \$3}' | grep -v -E '^/(\$|proc|sys|dev|run|tmp)'); do sudo umount \"\$mount_point\" 2>/dev/null; done; true"
    sync
    sudo exportfs -ra
    if [ $? -ne 0 ]; then echo "command "${FUNCNAME[1]}" "${BASH_SOURCE[1]}" "$LINENO" error"; return 1; fi
    sudo systemctl restart nfs-server
    if [ $? -ne 0 ]; then echo "command "${FUNCNAME[1]}" "${BASH_SOURCE[1]}" "$LINENO" error"; return 1; fi
    ${seNCtrl_PWD}/bmsec run $id "sudo mkdir -p ${seNCtrl_NFS_PATH_REMOTE}"
    ${seNCtrl_PWD}/bmsec run $id "sudo chmod 777 ${seNCtrl_NFS_PATH_REMOTE}"
    ${seNCtrl_PWD}/bmsec run $id "sudo mount -t nfs \$(netstat -nr | grep '^0.0.0.0' | awk '{print \$2}'):${seNCtrl_NFS_PATH_LOCAL} ${seNCtrl_NFS_PATH_REMOTE}"
    if [ $? -ne 0 ]; then echo "command "${FUNCNAME[1]}" "${BASH_SOURCE[1]}" "$LINENO" error"; return 1; fi
    docker_check=$(${seNCtrl_PWD}/bmsec run $id "command -v docker >/dev/null 2>&1 && sudo docker ps -q 2>/dev/null" 2>/dev/null | grep -v -E '^Core Id:|^\s*$' | tr -d '\r\n ')
    if [[ -n "$docker_check" ]]; then
        echo "ERROR: running docker containers detected on core $id, please stop them first (sudo docker stop \$(sudo docker ps -q))"
        return 1
    fi
    ${seNCtrl_PWD}/bmsec run $id "cd ${seNCtrl_NFS_PATH_REMOTE} && unzip -o socbak.zip"
    if [ $? -ne 0 ]; then echo "command "${FUNCNAME[1]}" "${BASH_SOURCE[1]}" "$LINENO" error"; return 1; fi
    if [[ "$userInputOnlyBak" == "onlyBak" ]]; then
        soc_arg="SOC_BAK_ALL_IN_ONE="
    elif [[ "$userInputOnlyBak" == "sdcard" ]]; then
        soc_arg="SOC_BAK_ALL_IN_ONE=sdcard"
    else
        soc_arg="SOC_BAK_ALL_IN_ONE=tftp"
    fi
    ${seNCtrl_PWD}/bmsec run $id "pushd ${seNCtrl_NFS_PATH_REMOTE}/socbak && sudo bash ./socbak.sh ${soc_arg}"
    if [ $? -ne 0 ]; then echo "command "${FUNCNAME[1]}" "${BASH_SOURCE[1]}" "$LINENO" error"; return 1; fi
}

userInputSubId=""
userInputLocalBak=""
userInputOnlyBak=""
if [ $# -eq 2 ] || [ $# -eq 3 ]; then
    userInputSubId="$1"
    userInputLocalBak="$2"
    userInputOnlyBak="$3"
else
    echo "Enter the sub id to store the packaged:"
    read userInputSubId
    echo "Enter the local dir path to store the packaged files:"
    read userInputLocalBak
    echo "Enter only bak mode (onlyBak|tftp|sdcard, default tftp):"
    read userInputOnlyBak
fi
if [[ "$userInputLocalBak" == "" ]] || [[ ! -d "$userInputLocalBak" ]]; then
    echo "ERROR: userInputLocalBak:$userInputLocalBak, exit"
    return 1
fi
if [[ "$userInputLocalBak" != /* ]]; then
    echo "ERROR: userInputLocalBak must be absolute path: $userInputLocalBak, exit"
    return 1
fi
avail_mb=$(df -BM --output=avail "$userInputLocalBak" 2>/dev/null | tail -1 | tr -d ' M')
if [[ -z "$avail_mb" || "$avail_mb" -lt "$SOCBAK_NFS_MIN_AVAIL_MB" ]]; then
    echo "ERROR: ${userInputLocalBak} avail ${avail_mb}MB < ${SOCBAK_NFS_MIN_AVAIL_MB}MB (3.75GB), please expand and retry"
    return 1
fi
if [[ "$userInputSubId" =~ ^[0-9]+$ &&  userInputSubId -ge 0 &&  userInputSubId -le $seNCtrl_ALL_SUB_NUM ]]; then
    ${seNCtrl_PWD}/bmsec run $userInputSubId "[ -e "/system/data/buildinfo.txt" ] && exit 1 || exit 0"
    if [ $? -ne 0 ]; then echo "Version 3.0.0 or older is not supported"; return 1; fi
    if [[ "${seNCtrl_ALL_SUB_IP[$(($userInputSubId - 1))]}" == "NAN" ]]; then echo "cannot support core Id:$userInputSubId"; return 1; fi
    nfsShareBak "$userInputSubId" "$userInputLocalBak" "/socrepack"
    if [ $? -ne 0 ]; then echo "command "${FUNCNAME[1]}" "${BASH_SOURCE[1]}" "$LINENO" error"; systemBakPack_cleanup; return 1; fi
    nfsConfig_cleanup
    if [[ "$userInputOnlyBak" == "onlyBak" ]]; then
        out_dir="${userInputLocalBak}/socbak/output"
    elif [[ "$userInputOnlyBak" == "sdcard" ]]; then
        out_dir="${userInputLocalBak}/socbak/output/sdcard"
    else
        out_dir="${userInputLocalBak}/socbak/output/tftp"
    fi
    echo "bakpack files in ${out_dir}:"
    ls -lah ${out_dir}
fi
