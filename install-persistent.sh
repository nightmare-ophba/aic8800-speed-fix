#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly UNIT_SOURCE="${ROOT_DIR}/aic8800-speed-fix@.service.in"
readonly UNIT_DEST="/etc/systemd/system/aic8800-speed-fix@.service"
readonly MODPROBE_DEST="/etc/modprobe.d/aic8800-speed-fix.conf"
readonly UDEV_DEST="/etc/udev/rules.d/41-aic8800-speed-fix.rules"
readonly LOCAL_DRIVER="${ROOT_DIR}/upstream-aic8800/src/USB/driver_fw/drivers/aic8800/aic8800_fdrv/aic8800_fdrv.ko"
readonly LOCAL_LOADER="${ROOT_DIR}/upstream-aic8800/src/USB/driver_fw/drivers/aic8800/aic_load_fw/aic_load_fw.ko"
readonly ROUTE_METRIC="${AIC8800_ROUTE_METRIC:-100}"

die() {
    printf '错误: %s\n' "$*" >&2
    exit 1
}

(( EUID == 0 )) || die '安装持久化驱动需要 root'
command -v systemctl >/dev/null 2>&1 || die '缺少 systemctl'
command -v udevadm >/dev/null 2>&1 || die '缺少 udevadm'
[[ -r ${UNIT_SOURCE} ]] || die "缺少服务模板: ${UNIT_SOURCE}"

"${ROOT_DIR}/build.sh"
[[ -r ${LOCAL_DRIVER} && -r ${LOCAL_LOADER} ]] || die '驱动构建产物不存在'
expected_vermagic=$(modinfo -F vermagic "${LOCAL_DRIVER}")
[[ ${expected_vermagic} == "$(uname -r)"* ]] || die "模块 vermagic 不匹配: ${expected_vermagic} / $(uname -r)"

root_escaped=${ROOT_DIR//\\/\\\\}
root_escaped=${root_escaped//|/\\|}
root_escaped=${root_escaped//&/\\&}
sed "s|@ROOT_DIR@|${root_escaped}|g" "${UNIT_SOURCE}" >"${UNIT_DEST}"
cat >"${MODPROBE_DEST}" <<'EOF'
# Keep the unpatched DKMS modules from being selected by USB modalias loading.
blacklist aic8800_fdrv
blacklist aic_load_fw
install aic8800_fdrv /bin/false
install aic_load_fw /bin/false
EOF
cat >"${UDEV_DEST}" <<'EOF'
# Load the local firmware driver when the device enters its WLAN boot mode.
ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="a69c", ATTR{idProduct}=="8d80", TAG+="systemd", ENV{SYSTEMD_WANTS}+="aic8800-speed-fix@%k.service"
ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="a69c", ATTR{idProduct}=="8d81", TAG+="systemd", ENV{SYSTEMD_WANTS}+="aic8800-speed-fix@%k.service"
EOF

systemctl daemon-reload
udevadm control --reload
install -d -m 0700 /var/lib/aic8800-speed-fix
usb_port=""
for usb_path in /sys/bus/usb/devices/*; do
    [[ -r ${usb_path}/idVendor && -r ${usb_path}/idProduct ]] || continue
    [[ $(<"${usb_path}/idVendor") == a69c ]] || continue
    [[ $(<"${usb_path}/idProduct") == 8d80 || $(<"${usb_path}/idProduct") == 8d81 ]] || continue
    usb_port=${usb_path##*/}
    break
done
[[ -n ${usb_port} ]] || die '未找到 AIC8800 USB 设备'

if command -v nmcli >/dev/null 2>&1; then
    aic_iface=""
    for iface_path in "/sys/bus/usb/devices/${usb_port}/net/"* "/sys/bus/usb/devices/${usb_port}/"*/net/*; do
        [[ -e ${iface_path} ]] || continue
        aic_iface=${iface_path##*/}
        break
    done
    if [[ -n ${aic_iface} ]]; then
        profile_uuid=""
        while IFS= read -r uuid; do
            bound_iface=$(nmcli -g connection.interface-name connection show uuid "${uuid}" 2>/dev/null || true)
            if [[ ${bound_iface} == "${aic_iface}" ]]; then
                profile_uuid=${uuid}
                break
            fi
        done < <(nmcli -g UUID connection show 2>/dev/null)
        if [[ -n ${profile_uuid} ]]; then
            [[ ${ROUTE_METRIC} =~ ^[0-9]+$ ]] || die 'AIC8800_ROUTE_METRIC 必须是非负整数'
            nmcli connection modify uuid "${profile_uuid}" ipv4.route-metric "${ROUTE_METRIC}"
        fi
    fi
fi

systemctl start "aic8800-speed-fix@${usb_port}.service"

loaded_srcversion=$(cat /sys/module/aic8800_fdrv/srcversion 2>/dev/null || true)
expected_srcversion=$(modinfo -F srcversion "${LOCAL_DRIVER}")
[[ -n ${loaded_srcversion} && ${loaded_srcversion} == "${expected_srcversion}" ]] \
    || die "加载的不是本地修复版模块: ${loaded_srcversion:-none} / ${expected_srcversion}"
printf '持久化安装完成，修复版模块已加载。\n'
printf 'srcversion: %s\n' "${loaded_srcversion}"
printf '重启后检查: systemctl status aic8800-speed-fix@${usb_port}.service; cat /sys/module/aic8800_fdrv/srcversion\n'
