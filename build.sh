#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SOURCE_DIR="${ROOT_DIR}/upstream-aic8800"
readonly DRIVER_DIR="${SOURCE_DIR}/src/USB/driver_fw/drivers/aic8800"
readonly SOURCE_URL="https://github.com/radxa-pkg/aic8800.git"
readonly SOURCE_COMMIT="5562c254b0231be34588dc608ec28c4f1d613285"

die() {
    printf '错误: %s\n' "$*" >&2
    exit 1
}

(( EUID == 0 )) || die '编译内核模块需要 root 读取当前内核构建目录；请使用 root 运行'
command -v git >/dev/null 2>&1 || die '缺少 git'
command -v make >/dev/null 2>&1 || die '缺少 make'
[[ -d /lib/modules/$(uname -r)/build ]] || die "缺少当前内核头文件: /lib/modules/$(uname -r)/build"

if [[ ! -e ${SOURCE_DIR}/.git ]]; then
    git clone --depth 1 "${SOURCE_URL}" "${SOURCE_DIR}"
fi
if ! git -C "${SOURCE_DIR}" cat-file -e "${SOURCE_COMMIT}^{commit}" 2>/dev/null; then
    git -C "${SOURCE_DIR}" fetch --depth 1 origin "${SOURCE_COMMIT}"
fi
git -C "${SOURCE_DIR}" checkout --detach "${SOURCE_COMMIT}"

patch_file="${ROOT_DIR}/ubuntu-6.8-cfg80211.patch"
if ! grep -q 'AIC_HAVE_SET_MONITOR_CHANNEL_DEV' "${DRIVER_DIR}/aic8800_fdrv/Makefile"; then
    git -C "${SOURCE_DIR}" apply "${patch_file}"
fi

make -C "/lib/modules/$(uname -r)/build" \
    M="${DRIVER_DIR}" \
    CC=/usr/bin/gcc-12 \
    modules | tee "${ROOT_DIR}/build.log"

mkdir -p "${ROOT_DIR}/artifacts"
cp -f "${DRIVER_DIR}/aic_load_fw/aic_load_fw.ko" "${ROOT_DIR}/artifacts/"
cp -f "${DRIVER_DIR}/aic8800_fdrv/aic8800_fdrv.ko" "${ROOT_DIR}/artifacts/"
sha256sum "${ROOT_DIR}/artifacts/"*.ko | tee "${ROOT_DIR}/artifacts/SHA256SUMS"
printf '编译完成。运行 load-local-driver.sh 仅加载新目录中的模块。\n'
