# AIC8800D80 Linux 传输速度修复包

本目录针对 USB `AICSemi AIC 8800D80`（`a69c:8d81`）和 Ubuntu 6.8 内核提供隔离的驱动构建与加载流程。上游源码来自 `https://github.com/radxa-pkg/aic8800`，固定提交为 `5562c254b0231be34588dc608ec28c4f1d613285`。

## 补丁说明、测试状态与许可证

`ubuntu-6.8-cfg80211.patch` 是针对上述上游源码的本地修改补丁，由 AI 生成。应用补丁后，上游源码树会被修改；补丁调整 `cfg80211` 回调签名兼容检测、修改 Ubuntu 固件目录，并启用 USB RX 聚合。该补丁尚未经过完整测试，不能视为已验证可用于所有内核、设备或运行场景。使用者应在目标环境自行审查、测试并承担使用风险。

本项目引用并基于 [radxa-pkg/aic8800](https://github.com/radxa-pkg/aic8800) 的源码，固定上游版本为提交 [`5562c254b0231be34588dc608ec28c4f1d613285`](https://github.com/radxa-pkg/aic8800/commit/5562c254b0231be34588dc608ec28c4f1d613285)。上游 `debian/copyright` 将 `src/*` 标注为 GPL-2，将其他文件标注为 GPL-3+；该文件列明上游版权归属为 Radxa Computer Co., Ltd。本补丁修改的是 `src/*` 下的文件，随该部分源码分发时遵循 GPL-2，并标明其已修改。完整许可条款及上游版权声明见 `upstream-aic8800/LICENSE`、`upstream-aic8800/debian/copyright` 和各源文件原有声明。本仓库脚本及其他独立文件的许可范围以对应文件声明及上游许可证文件为准。

曾观察到 RX PHY 480.3 Mbps、TX PHY 286.7 Mbps；这些是会波动的 PHY 读数，未做同条件端到端吞吐对照。驱动对 D81 产品 ID 会在运行时启用 USB RX 聚合，Makefile 同时为其他 USB 型号启用对应编译路径。由于外部测速站点从测试主机不可达，实际下载速度仍待测，不能据此宣称下载问题已完全解决。补丁还增加 `cfg80211` 回调兼容检测并调整 Ubuntu 固件目录；加载脚本会关闭驱动省电，并启用 HE/VHT/80 MHz 参数。AIC8800D81 在当前上游驱动中实际只广告 1 条空间流。仓库提供一致的构建、加载和路由配置，但无法保证不同主机、USB 控制器、AP、信道环境及互联网线路都达到相同吞吐或超过 200 Mbps。

使用方式：

```bash
git clone --recurse-submodules https://github.com/nightmare-ophba/aic8800-speed-fix.git
cd aic8800-speed-fix
sudo ./build.sh
sudo ./diagnose.sh
sudo ./load-local-driver.sh
sudo ./diagnose.sh
```

要让修复版驱动在重启和 USB 重新枚举后自动加载，运行一次：

```bash
sudo ./install-persistent.sh
```

安装器会构建当前内核对应的模块，禁止未修复的 DKMS 模块通过 USB 自动加载，并注册 systemd/udev 服务，在启动和 USB 重新枚举时加载本地模块。若找到绑定 AIC 接口的 NetworkManager 配置，安装器会将其 IPv4 路由 metric 设为 `100`，使 AIC 优先作为默认出口，其他网卡仍可作为备用。若本地模块不匹配当前内核或加载失败，服务不会回退到 DKMS；可用以下命令确认实际加载的是本地修复版：

```bash
systemctl list-units --all 'aic8800-speed-fix@*.service'
cat /sys/module/aic8800_fdrv/srcversion
modinfo -F srcversion upstream-aic8800/src/USB/driver_fw/drivers/aic8800/aic8800_fdrv/aic8800_fdrv.ko
```

`load-local-driver.sh` 只卸载并重新加载 USB `a69c:8d81` 网卡的内核模块。它会把加载前状态写入 `state/`；本地驱动加载失败时会报告失败，不会切回系统 DKMS 驱动。

加载完成后，脚本会为 AIC 接口当前获得的 IPv4 地址建立源地址策略路由，并设置该接口的 ARP 归属。服务器进程可以监听 AIC 网卡的实际地址；可用以下命令确认来自该地址的回包固定走 AIC 接口：

```bash
AIC_IP="${AIC_IP:?设置为 AIC 网卡当前 IPv4 地址}"
ip route get 1.1.1.1 from "$AIC_IP"
ss -lntp
```

使用另一台局域网客户端做服务器发送方向的基准测试。服务器端只监听 AIC 地址，客户端用 `-R` 测试从服务器下载；连续 20 秒、4 条并行流的结果应作为是否达到 200 Mbps 的依据：

```bash
# 服务器
iperf3 -s -B "$AIC_IP"

# 另一台客户端
iperf3 -c "$AIC_IP" -R -P 4 -t 20
```

当前测试主机没有可用的第二台客户端，无法在本机证明超过 200 Mbps；PHY 速率读数不能替代该端到端测试。

无线实际吞吐还取决于 AP 的 80 MHz 能力、信道、信号质量和 USB 物理链路。脚本不会伪造链路速率，也不会修改 NetworkManager 连接密码或地址。
