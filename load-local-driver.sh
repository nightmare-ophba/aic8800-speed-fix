#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly DRIVER_DIR="${AIC8800_DRIVER_DIR:-${ROOT_DIR}/upstream-aic8800/src/USB/driver_fw/drivers/aic8800}"
readonly STATE_DIR="${AIC8800_STATE_DIR:-${ROOT_DIR}/state}"
readonly IFACE_HINT="${AIC8800_IFACE:-}"
readonly SYSTEM_FW_DIR="/lib/firmware/aic8800_fw/USB"
readonly POLICY_TABLE="${AIC8800_POLICY_TABLE:-23000}"

is_target_iface() {
    local iface="$1"
    local device
    device=$(readlink -f "/sys/class/net/${iface}/device" 2>/dev/null) || return 1
    while [[ ${device} == /sys/* ]]; do
        if [[ -r ${device}/idVendor && -r ${device}/idProduct ]] \
            && [[ $(<"${device}/idVendor") == a69c ]] \
            && [[ $(<"${device}/idProduct") == 8d80 || $(<"${device}/idProduct") == 8d81 ]]; then
            return 0
        fi
        [[ ${device} == /sys ]] && break
        device=${device%/*}
    done
    return 1
}

find_target_iface() {
    local usb_path iface_path iface vendor product path
    if [[ -n ${IFACE_HINT} ]] && is_target_iface "${IFACE_HINT}"; then
        printf '%s\n' "${IFACE_HINT}"
        return 0
    fi
    for path in /sys/class/net/*; do
        iface=${path##*/}
        if is_target_iface "${iface}"; then
            printf '%s\n' "${iface}"
            return 0
        fi
    done
    for usb_path in /sys/bus/usb/devices/*; do
        [[ -r ${usb_path}/idVendor && -r ${usb_path}/idProduct ]] || continue
        vendor=$(<"${usb_path}/idVendor")
        product=$(<"${usb_path}/idProduct")
        [[ ${vendor} == a69c && ( ${product} == 8d80 || ${product} == 8d81 ) ]] || continue
        for iface_path in "${usb_path}"/*/net/*; do
            [[ -e ${iface_path} ]] || continue
            iface=${iface_path##*/}
            printf '%s\n' "${iface}"
            return 0
        done
    done
    return 1
}

die() {
    printf '错误: %s\n' "$*" >&2
    exit 1
}

configure_source_routing() {
    local iface="$1"
    local address prefix gateway
    local -a addresses=()

    while IFS= read -r address; do
        [[ -n ${address} ]] && addresses+=("${address}")
    done < <(ip -o -4 addr show dev "${iface}" scope global | awk '{split($4, parts, "/"); print parts[1]}')
    ((${#addresses[@]} > 0)) || return 0

    ip route flush table "${POLICY_TABLE}" >/dev/null 2>&1 || true
    while IFS= read -r prefix; do
        [[ -n ${prefix} ]] || continue
        ip route replace table "${POLICY_TABLE}" "${prefix}" dev "${iface}" src "${addresses[0]}"
    done < <(ip -4 route show dev "${iface}" scope link | awk '$1 ~ /^[0-9]/ {print $1}')

    gateway=$(ip -4 route show default dev "${iface}" \
        | awk '$1 == "default" {for (i = 1; i <= NF; i++) if ($i == "via") {print $(i + 1); exit}}')
    if [[ -n ${gateway} ]]; then
        ip route replace table "${POLICY_TABLE}" default via "${gateway}" dev "${iface}" src "${addresses[0]}"
    else
        ip route replace table "${POLICY_TABLE}" default dev "${iface}" src "${addresses[0]}"
    fi

    # Keep replies to services addressed on this adapter on the same adapter.
    sysctl -q -w "net.ipv4.conf.${iface}.arp_filter=1" || true
    sysctl -q -w "net.ipv4.conf.${iface}.arp_announce=2" || true
    for address in "${addresses[@]}"; do
        ip rule del priority 1000 from "${address}/32" table "${POLICY_TABLE}" >/dev/null 2>&1 || true
        ip rule add priority 1000 from "${address}/32" table "${POLICY_TABLE}"
    done
}

(( EUID == 0 )) || die '加载本地内核模块需要 root'
[[ -r ${DRIVER_DIR}/aic8800_fdrv/aic8800_fdrv.ko ]] || die '尚未编译 aic8800_fdrv.ko，请先运行 build.sh'
[[ -r ${DRIVER_DIR}/aic_load_fw/aic_load_fw.ko ]] || die '尚未编译 aic_load_fw.ko，请先运行 build.sh'
command -v lsusb >/dev/null 2>&1 || die '缺少 lsusb'
command -v modinfo >/dev/null 2>&1 || die '缺少 modinfo'
command -v insmod >/dev/null 2>&1 || die '缺少 insmod'

for attempt in {1..60}; do
    lsusb -d a69c:8d80 >/dev/null 2>&1 || lsusb -d a69c:8d81 >/dev/null 2>&1 && break
    sleep 1
done
lsusb -d a69c:8d80 >/dev/null 2>&1 || lsusb -d a69c:8d81 >/dev/null 2>&1 || die '未检测到 AICSemi AIC8800D80 (USB a69c:8d80/8d81)'
[[ -d ${SYSTEM_FW_DIR} ]] || die "系统固件目录不存在: ${SYSTEM_FW_DIR}"
expected_vermagic=$(modinfo -F vermagic "${DRIVER_DIR}/aic8800_fdrv/aic8800_fdrv.ko")
[[ ${expected_vermagic} == "$(uname -r)"* ]] || die "模块 vermagic 不匹配: ${expected_vermagic} / $(uname -r)"
expected_srcversion=$(modinfo -F srcversion "${DRIVER_DIR}/aic8800_fdrv/aic8800_fdrv.ko")

mkdir -p "${STATE_DIR}"
date -Is >"${STATE_DIR}/last-load.txt"
modinfo aic8800_fdrv >"${STATE_DIR}/previous-driver.txt" 2>&1 || true
iw dev >"${STATE_DIR}/previous-wireless.txt" 2>&1 || true

iface=$(find_target_iface || true)

if command -v nmcli >/dev/null 2>&1 && [[ -n ${iface} ]]; then
    nmcli device disconnect "${iface}" >/dev/null 2>&1 || true
fi
if [[ -n ${iface} ]]; then
    ip link set dev "${iface}" down >/dev/null 2>&1 || true
fi

modprobe -r aic8800_fdrv >/dev/null 2>&1 || rmmod aic8800_fdrv >/dev/null 2>&1 || die '无法卸载旧的 aic8800_fdrv（可能仍有进程占用）'
modprobe -r aic_load_fw >/dev/null 2>&1 || rmmod aic_load_fw >/dev/null 2>&1 || true

insmod "${DRIVER_DIR}/aic_load_fw/aic_load_fw.ko"
insmod "${DRIVER_DIR}/aic8800_fdrv/aic8800_fdrv.ko" \
    ps_on=0 \
    use_80=1 \
    use_2040=1 \
    he_on=1 \
    vht_on=1 \
    ht_on=1 \
    mcs_map=2 \
    he_mcs_map=2 \
    nss=2 \
    sgi=1 \
    sgi80=1 \
    ldpc_on=1 \
    stbc_on=1 \
    amsdu_rx_max=2 \
    aicwf_dbg_level=1

new_iface=""
for attempt in {1..45}; do
    new_iface=$(find_target_iface || true)
    [[ -n ${new_iface} ]] && break
    sleep 1
done
[[ -n ${new_iface} ]] || die '新驱动已加载，但没有找到无线接口'

iw dev "${new_iface}" set power_save off >/dev/null 2>&1 || true
if command -v nmcli >/dev/null 2>&1; then
    profile_uuid=""
    while IFS= read -r uuid; do
        bound_iface=$(nmcli -g connection.interface-name connection show uuid "${uuid}" 2>/dev/null || true)
        if [[ ${bound_iface} == "${new_iface}" ]]; then
            profile_uuid=${uuid}
            break
        fi
    done < <(nmcli -g UUID connection show 2>/dev/null)
    if [[ -n ${profile_uuid} ]]; then
        nmcli connection up uuid "${profile_uuid}" ifname "${new_iface}" >/dev/null 2>&1 || true
    else
        nmcli device connect "${new_iface}" >/dev/null 2>&1 || true
    fi
fi

for attempt in {1..30}; do
    if iw dev "${new_iface}" link 2>/dev/null | grep -q '^Connected to '; then
        break
    fi
    sleep 1
done

configure_source_routing "${new_iface}"

printf '已加载隔离目录中的驱动: %s\n' "${new_iface}"
modinfo "${DRIVER_DIR}/aic8800_fdrv/aic8800_fdrv.ko" | grep -E '^(filename|version|srcversion|vermagic):'
loaded_srcversion=$(cat /sys/module/aic8800_fdrv/srcversion 2>/dev/null || true)
[[ -n ${expected_srcversion} && ${loaded_srcversion} == "${expected_srcversion}" ]] \
    || die "加载的模块不是本地修复版: ${loaded_srcversion:-none} / ${expected_srcversion}"
iw dev "${new_iface}" link || true
printf '当前参数:\n'
for path in /sys/module/aic8800_fdrv/parameters/{ps_on,use_80,use_2040,he_on,vht_on,nss}; do
    [[ -e ${path} ]] && printf '  %s=' "${path##*/}" && cat "${path}"
done
