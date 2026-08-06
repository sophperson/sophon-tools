#!/bin/bash

product=$(cat /sys/bus/i2c/devices/1-0017/information 2> /dev/null | grep model | awk -F \" '{print $4}')
seNCtrl_DEBUG_UART=""
se_files=($(sudo find /root -maxdepth 1 -type d -name 'se*' -exec find {} -maxdepth 1 -type f -name 'se*ctr.sh' \;))
export seNCtrl_SENCRT_PATH="${se_files[0]}"
if [ "$seNCtrl_SENCRT_PATH" = "" ]; then echo "cannot find sectr, exit"; exit -1; fi
fileName=$(basename "$seNCtrl_SENCRT_PATH")
seNCtrl_SENCRT_HEADER="${fileName%%.sh}"
seNCtrl_SUB_IP_HALF=""
seNCtrl_HOST_SUB_ETHS=()
if [ "$product" = "SE6-CTRL" ] || [ "$product" = "SE6 CTRL" ] || [ "$product" = "SM7 CTRL" ] || [ "$product" = "SE8 CTRL" ]; then
    seNCtrl_HOST_SUB_ETHS+=('eth0' 'eth1')
    seNCtrl_DEBUG_UART=/dev/ttyS2
    YAML_FILE="/etc/netplan/01-netcfg.yaml"
    INTERFACE_0="eth0"
    INTERFACE_1="eth1"
    # WAN="enp4s0"
else #se8 x86
    if [ -f /factory/OEMconfig.ini ]; then #se8-s1 or se8-2u
        seNCtrl_HOST_SUB_ETHS+=('eno1' 'enp2s0f0' 'bond0')
        seNCtrl_DEBUG_UART=/dev/ttyS1
        YAML_FILE="/etc/netplan/01-network-manager-all.yaml"
        INTERFACE_0="enp2s0f0"
        INTERFACE_1="enp2s0f1"
        INTERFACE_2="enp2s0f2"
        WAN="enp4s0f0"
    else # se8-288
        seNCtrl_HOST_SUB_ETHS+=('eno1' 'enp2s0f0' 'bond0')
        seNCtrl_DEBUG_UART=/dev/ttyS1
        YAML_FILE="/etc/netplan/01-network-manager-all.yaml"
        INTERFACE_0="eno1"
        INTERFACE_1="eno3"
        WAN="eno5"
    fi
fi

source ${seNCtrl_PWD}/configs/sub/subInfo.12
if ifconfig | grep "^br" > /dev/null 2>&1 && [ "$Bridge_CONFIG_FLAG" == "1" ]; then
    seNCtrl_SUB_IP_HALF=$Bridge_IP_HALF 
    # echo $seNCtrl_SUB_IP_HALF
    
    #check if netplan yaml of eth0/1 is null
    ETH0_ADDRESSES=$(sudo grep -A 2 "$INTERFACE_0:" "$YAML_FILE" | grep "addresses:" | awk '{print $2}' | tr -d '[]')
    ETH1_ADDRESSES=$(sudo grep -A 2 "$INTERFACE_1:" "$YAML_FILE" | grep "addresses:" | awk '{print $2}' | tr -d '[]')
    # check eth0 addresses
    if [ -n "$ETH0_ADDRESSES" ]; then
        sudo sed -i "/$INTERFACE_0:/,/addresses:/ {
            s/addresses: \[[^]]*\]/addresses: []/
        }" $YAML_FILE
    fi

    # check eth1 addresses
    if [ -n "$ETH1_ADDRESSES" ]; then
        sudo sed -i "/$INTERFACE_1:/,/addresses:/ {
            s/addresses: \[[^]]*\]/addresses: []/
        }" $YAML_FILE
    fi

    if [ -n "$ETH0_ADDRESSES" ] || [ -n "$ETH1_ADDRESSES" ]; then
        echo "$INTERFACE_0 and $INTERFACE_1 is not null!"
        echo "So set them null, net config..."
        sudo netplan apply
        sleep 5
    fi

else
    #seNCtrl_SUB_IP_0 and seNCtrl_SUB_IP_1 are for bridges config
    seNCtrl_SUB_IP_0=$(ip addr show "$INTERFACE_0" | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
    seNCtrl_SUB_IP_1=$(ip addr show "$INTERFACE_1" | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
    for eth in "${seNCtrl_HOST_SUB_ETHS[@]}"; do
        seNCtrl_SUB_IP_HALF=$(ifconfig "$eth" 2> /dev/null | grep "inet "|awk '{print $2}'|awk -F . '{printf("%d.%d\n", $1,$2)}')
        if [ -n "$seNCtrl_SUB_IP_HALF" ]; then break; fi
    done
fi

if [ "$seNCtrl_SUB_IP_HALF" = "" ]; then echo "cannot get ip to core, exit"; ifconfig; exit -1; fi
source <(sed 's/172\.16/${seNCtrl_SUB_IP_HALF}/g' ${seNCtrl_PWD}/configs/sub/subInfo.12)
sudo chmod 777 ${seNCtrl_DEBUG_UART}
if [ ! -e "${seNCtrl_PWD}/configs/subNANInfo" ]; then
    echo "init info not, make it..."
    sudo touch ${seNCtrl_PWD}/configs/subNANInfo
    sudo chmod 777 ${seNCtrl_PWD}/configs/subNANInfo
    for ((id = 1; id <= $seNCtrl_ALL_SUB_NUM; id++)); do
        ret=$(sudo bash -c "source ${seNCtrl_SENCRT_PATH}; ${seNCtrl_SENCRT_HEADER}_get_aiu_pg ${id} 2> /dev/null;")
        ret=$(echo "$ret" | tail -n 1)
        if [[ "$ret" =~ ^[0-9]+$ && "$ret" -ge 1 ]]; then
            echo "core ${id} is power good"
        else
            echo "core ${id} is not power good"
            echo "${id}" >> ${seNCtrl_PWD}/configs/subNANInfo
        fi
    done
fi

while IFS= read -r id || [[ -n "$id" ]]; do
    if [[ "$id" =~ ^[0-9]+$ &&  id -ge 1 &&  id -le $seNCtrl_ALL_SUB_NUM ]]; then
        seNCtrl_ALL_SUB_IP_ID["${seNCtrl_ALL_SUB_IP[$(($id - 1))]}"]=""
        seNCtrl_ALL_SUB_IP[$(($id - 1))]="NAN"
    fi
done < "${seNCtrl_PWD}/configs/subNANInfo"
