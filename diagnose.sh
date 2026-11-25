#!/usr/bin/env bash
set -Eeuo pipefail

readonly IFACE="${AIC8800_IFACE:-}"

die() {
    printf '错误: %s\n' "$*" >&2
    exit 1
}

command -v ip >/dev/null 2>&1 || die '缺少 ip'
command -v iw >/dev/null 2>&1 || die '缺少 iw'

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

printf '内核: '; uname -r
printf 'USB 设备:\n'
lsusb -d a69c:8d80 2>/dev/null || lsusb -d a69c:8d81 2>/dev/null || true
printf '\n网卡驱动:\n'
for path in /sys/class/net/*; do
    name=${path##*/}
    [[ ${name} == lo || ${name} == veth* || ${name} == br-* || ${name} == docker0 || ${name} == cni0 || ${name} == flannel.* ]] && continue
    printf '%s: ' "${name}"
    readlink "${path}/device/driver" 2>/dev/null | sed 's#^.*/##' || printf 'unknown'
done

iface=${IFACE}
if [[ -z ${iface} ]]; then
    for path in /sys/class/net/*; do
        name=${path##*/}
        if is_target_iface "${name}"; then
            iface=${name}
            break
        fi
    done
fi
[[ -n ${iface} ]] || die '未找到 aic8800 无线网卡；可用 AIC8800_IFACE 指定接口'

printf '\n接口: %s\n' "${iface}"
ip -br addr show dev "${iface}"
printf '\n无线链路:\n'
iw dev "${iface}" link || true
printf '\n无线能力/信道:\n'
iw dev "${iface}" info || true
printf '\n功耗策略:\n'
iw dev "${iface}" get power_save || true
printf '\n驱动参数:\n'
for path in /sys/module/aic8800_fdrv/parameters/*; do
    printf '%s=' "${path##*/}"
    cat "${path}"
done 2>/dev/null || true
printf '\n最近驱动日志:\n'
dmesg --color=never 2>/dev/null | grep -i -E 'aic|usb.*(err|reset)|urb' | tail -80 || true
