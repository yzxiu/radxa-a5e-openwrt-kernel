# A5E WiFi 驱动（AIC8800）调研与集成方案

> 状态：✅ **全部完成并板上验收**（2026-10-06，`feature/aic8800-builtin`）。
> 驱动 builtin 进 vmlinux，冷启动零人工干预，~8s 自动出 AP 并桥接进 br-lan（见 §5 验收记录）。
> 踩过的坑全部沉淀在 §5 第三/四步；image 仓待办见 §7。
> bridge/firewall4 早前已根治（builtin）并烧录验收。
> 相关：[A5E-内核编译-记录.md](A5E-内核编译-记录.md)（内核流水线）、
> [OpenWrt镜像-定制内核替换.md](OpenWrt镜像-定制内核替换.md)（镜像替换流程）、
> 主项目《OpenWrt-A5E-制作记录.md》坑 8 与展望节。

## 0. TL;DR

| 项 | 结论 |
|---|---|
| 芯片 | AIC8800**D80**（板载 SDIO，2.4G 单频，HT/VHT/HE 全支持；vid `0xC8A1`） |
| 驱动形态 | 上游是 **DKMS 外置包**（`aic8800-sdio 5.0+git20260123`），不在内核源码树内 |
| 本仓库做法 | 把该 DKMS 源码**清洗移植进内核树 builtin**（`vendor/aic8800`，符号隔离 `AICV_*`） |
| 固件 | 必须随镜像分发；驱动用 **`filp_open` 直读**（非 `request_firmware`），路径由
  `CONFIG_AIC_FW_PATH` 编译期写死 = `/lib/firmware/aic8800_fw/SDIO/aic8800D80` |
| 初始化时机 | **异步内核线程**，轮询真 rootfs 就绪后初始化（initcall 里同步做会卡死启动，见 §5 第三步） |
| 用户态 | 需禁用 wpad 降权（否则 hostapd 不注册 ubus 对象，AP 永远起不来，见 §5 第四步） |
| 验收 | ✅ 冷启动零干预：`phy0-ap0` AP-ENABLED + 桥接 br-lan，`lsmod` 无 aic |

## 1. 硬件

Radxa Cubie A5E 板载 WiFi：

- 芯片：**AIC8800**（爱科微，WiFi6 单天线 + 蓝牙 combo）
- 总线：**SDIO**（驱动 probe 靠 `sdio:c07v*d*` 别名匹配）
- 注意：**不是** PCIe/M.2 外置网卡，是焊在板上的，DTB 里已描述，无插拔问题

## 2. 驱动：三个模块 + 固件

### 2.1 模块清单

Radxa 通过 DKMS 包 `aic8800-sdio 5.0+git20260123.5f7be68d-8` 分发，装到
`lib/modules/<KVER>/updates/dkms/`（DKMS 标准位置，**不在内核树内**）：

| 模块 | 作用 | depends | 备注 |
|---|---|---|---|
| `aic8800_bsp_sdio.ko` | BSP 底层：SDIO 探测、上电时序、固件下载通道 | 无 | 必须先加载 |
| `aic8800_fdrv_sdio.ko` | RivieraWaves 全 MAC 驱动（802.11 数据面） | `cfg80211, aic8800_bsp` | WiFi 本体 |
| `aic8800_btlpm_sdio.ko` | 蓝牙低功耗 | `aic8800_bsp` | 只做 WiFi 可暂不管 |

`modinfo` 关键信息（实测）：

```
aic8800_fdrv_sdio:
  version:     6.4.3.0
  description: RivieraWaves 11nac driver for Linux cfg80211
  firmware:    rwnx_settings.ini, fmacfw.bin, fmacfw.ihex,
               ldpcram.bin, fcuram.bin, agcram.bin
  depends:     cfg80211, aic8800_bsp
  vermagic:    6.6.98-1-aw2607 SMP mod_unload aarch64
aic8800_bsp_sdio:
  alias:       sdio:c07v*d*
  vermagic:    6.6.98-1-aw2607 SMP mod_unload aarch64
```

**vermagic 与本仓库构建的内核版本一致**（Radxa DKMS 在同一 KVER 上构建），
预编译 `.ko` 直接可用，不必重编。

### 2.2 固件机制：为什么"躲不掉"

WiFi 芯片是**半软硬分离**设计：跑 802.11 协议栈的代码在芯片自带 MCU 上，
驱动启动时通过内核 `request_firmware()` 接口从 **`/lib/firmware/`** 读固件文件，
再经 SDIO 下载进芯片 RAM，芯片才真正工作。

- 这是**运行时**动作：不管驱动是模块还是 builtin（`CONFIG_X=y`），
  文件都必须在 rootfs 里存在。builtin 只省掉 `.ko` 加载，**省不掉固件分发**。
- 固件缺失的表象：`dmesg` 报 `Direct firmware load for <名字> failed`，
  驱动 probe 失败，系统里完全看不到无线设备。

### 2.3 固件目录结构（Debian 包实测）

```
/usr/lib/firmware/aic8800_fw/
├── SDIO/
│   ├── aic8800/       ← 14 个文件：fmacfw.bin (253KB), fw_patch.bin, fw_adid.bin …
│   ├── aic8800D80/    ← 文件名带型号版本：fmacfw_8800d80_u02.bin …
│   ├── aic8800D80N/
│   ├── aic8800D80X2/
│   └── aic8800DC/
└── PCIE/              ← 同构的另一套（我们用不到）
```

**两个必须对齐的事实**：

1. 驱动 `modinfo` 请求的固件名是**无型号后缀**的裸名（`fmacfw.bin` 等），
   只存在于 `SDIO/aic8800/` 子目录；
2. 但驱动 bsp 层 Makefile 里硬编码了查找路径：

   ```makefile
   CONFIG_AIC_FW_PATH = "/lib/firmware/aic8800_fw/SDIO/aic8800D80"
   ```

   `aic8800D80/` 里并没有裸名文件。Debian 上能工作说明 Radxa 的包在某处
   （编译参数 / 补丁 / 运行时行为）配平了这件事。

> ⚠️ **待板上验证**：拷贝固件时到底哪个子目录/哪些文件被真正 request，
> 以 `dmesg | grep -i firmware` 实测为准，不要盲目整目录搬运。

## 3. 为什么不能像 bridge 一样"一行 CONFIG 编进内核"（以及实际怎么做的）

| | bridge / firewall4 | aic8800 |
|---|---|---|
| 源码位置 | 内核源码树内（`net/bridge/` 等） | **树外**（DKMS 单独发包） |
| Kconfig 符号 | 现成（`CONFIG_BRIDGE` 等） | 内核树里**不存在** `CONFIG_AIC_*` |
| fragment 追加 | 直接生效 | 写了没东西可勾 |

### 3.1 意外发现：bsp 子模块自带一份 AIC8800，且 Radxa 官方是禁用的

`linux-aw2607` 的 `bsp` 子模块（radxa/allwinner-bsp）里**自带完整同芯片驱动**
（`bsp/drivers/net/wireless/aic8800/`，比 DKMS 版更新：带芯片接口 choice、btusb、
aic8800p_fdrv），`device-a527` 的 `bsp_defconfig` 也启用了它
（`AIC_WLAN_SUPPORT=y, AIC8800_WLAN_SUPPORT=m, AIC8800_BTLPM_SUPPORT=m`）。

**但 radxa.config 第 1113 行显式 `CONFIG_AIC_WLAN_SUPPORT=n`**——Radxa 官方选择禁用
树内副本、走 DKMS 分发（Debian 根文件系统里实测只有 DKMS 产物，没有 bsp 副本的 .ko）。
注意 bsp 版驱动的固件接口不同：按 `aic8800d80/xxx.bin` 相对名 request_firmware，
需要另一套固件布局 + 未随 Debian 分发的 `aichw.conf`，**不要换用**。

### 3.2 实际实施方案（已落地，feature/aic8800-builtin）

以板上验证过的 DKMS 5.0+git20260123 源码为基准，清洗移植进内核树：

1. **`vendor/aic8800/`**（140 文件 4.5MB，`scripts/vendor-aic8800.sh` 生成）：
   - 删除 DKMS 外部编译 cruft（Platform ifeq、`all/modules/install` 等显式目标
     ——与 kbuild 全局目标重名会覆盖 `modules` 规则）；
   - **符号隔离**：Kconfig 符号改名 `AICV_*`，避免与 bsp 副本的开关互相干扰
     （源码不引用这些宏，全量 grep 验证过；`AIC_FW_PATH` 例外——源码直接引用
     其 C 宏且 bsp 树无此符号，保留原名，autoconf 直接生成）；
   - **同名内部符号去重**（builtin 的关键障碍）：DKMS 双模块架构里 bsp/fdrv
     各带一份私有同名副本（md5、SDIO 传输层、cmd 助手、全局变量，nm 实测 54 个），
     做模块互不冲突，builtin 进同一 vmlinux 会 multiple definition。
     经 nm 全量核实未定义引用均为模块内自包含后，bsp 侧 54 个符号统一
     `ccflags-y += -D原名=aicv_bsp_原名`（源码级改名，定义与引用一致改写），
     fdrv 侧保持原名，两模块私有副本语义原样保留。
2. **`patches/0001-aic8800-kbuild-wiring.patch`**：`drivers/net/wireless/` 的
   Kconfig（endif # WLAN 前 source）与 Makefile（obj-$(CONFIG_AICV_WLAN_SUPPORT)）接线。
3. **fragment**：`CFG80211=y / MAC80211=y / AICV_*=y / AIC_WLAN_SUPPORT=n /
   AIC_FW_PATH="/lib/firmware/aic8800_fw/SDIO/aic8800D80"`。
4. **verify.sh 新增**：模块目录无 `aic*.ko` 残留 + vmlinux 符号抽查
   （`aicbsp_init` / `aicwf_sdio_bus_init` / `aicv_bsp_*`）。

本地 16 核全量构建通过，verify.sh 全绿；vmlinux 内同时存在 fdrv 原名符号
与 bsp 改名符号，链接语义与双模块运行时一致。

## 4. 镜像缺口（内核侧已清零，剩固件 + 用户态两处）

对照本仓库产物与 image 仓（`radxa-a5e-openwrt`）流水线实测：

1. ~~kernel 产物里没有 aic8800 模块~~ **✅ 已根治**：驱动整体 builtin，
   模块目录无任何 `aic*.ko`（bsp/fdrv 进 vmlinux）；
2. ~~cfg80211/mac80211 是 `.ko` 模块~~ **✅ 已根治**：随 fragment `=y` builtin；
3. **⬜ 镜像里没有固件**——需把 `aic8800_fw/SDIO/aic8800D80/` 拷进 `/lib/firmware/`
   （驱动 filp_open 直读该目录，路径编译期写死）；
4. **⬜ wpad 默认降权到 `network` 用户 → hostapd 不注册 ubus 对象** → AP 起不来
   （详见 §5 第四步，一行改名即可修）；
5. **⬜ armsr rootfs 缺 `iw` / `wifi-scripts` 两个包**——`/sbin/wifi` 命令来自
   `wifi-scripts`（25.12 才拆出来的新包），没有它 `wifi config/up` 全都 `not found`；
   `iw` 用于调试。需 `apk add iw wifi-scripts` 或预置进镜像。

> 注：用户态原本以为"无缺口"（wpad/hostapd/iwinfo 库都在），实测下来 3/4/5 三项
> 都得在 image 仓处理，清单见 §7。

## 5. 路线图

### 第一步：板上手动验证（不改仓库，一次性排掉所有未知）

向现有 `owrt-a5e.img` 的 rootfs 分区（p3，LBA 679936 / 488MB ext4，
流程见《OpenWrt镜像-定制内核替换.md》§3-§4）注入：

```
lib/modules/6.6.98-1-aw2607/updates/dkms/
    aic8800_bsp_sdio.ko      ← 从 Debian rootfs 资产解压（.ko.xz → .ko）
    aic8800_fdrv_sdio.ko
    aic8800_btlpm_sdio.ko    ← 可选
lib/firmware/aic8800_fw/SDIO/aic8800/   ← 先按 §2.3 对齐后的结论拷
```

板上验证清单（2026-10-06 **全部完成，WiFi 点亮**）：

- [x] `insmod aic8800_bsp_sdio.ko && insmod aic8800_fdrv_sdio.ko`（顺序）——成功；
      **注意 cfg80211/mac80211 当时还是模块，需先 insmod，否则 fdrv 报
      Unknown symbol（builtin 后此问题自然消失）**
- [x] `dmesg` 实测固件路径 = **`/lib/firmware/aic8800_fw/SDIO/aic8800D80/fmacfw_8800d80_u02.bin`**
      ——§2.3 疑点解决：芯片是 D80 变体，硬编码路径正确；
      固件是 **filp_open 直读**（`CONFIG_USE_FW_REQUEST=n`），不是 request_firmware
- [x] `ip link` 出现 `wlan0`；`iw dev wlan0 scan` 扫到周边 AP（信号正常）；
      芯片 HT/VHT/HE 全支持（WiFi6），**实际 2.4G 单频**（uci 自动配置的 5g/ch36 是误判，需手改 2g）
- [x] 手工 hostapd 起 AP：**AP-ENABLED 成功**，SSID 可广播
- [ ] uci/netifd 自动配 AP（`wifi up`）：**卡 `command failed: Not supported (-95)`**，
      纯软件集成问题，netifd/wifi-scripts 对 fullmac 驱动的兼容，待单独排查

### 第二步：根治 ✅ 已完成并板上验收（走了方案 B 的改进版）

按 §3.2 落地：vendor 进内核树 builtin，用**板上验证过的 DKMS 源码**而非 bsp 副本，
符号隔离 + 54 个内部符号改名解决双模块私有副本的 builtin 链接障碍。

### 第三步：builtin 冷启动时序（三轮板验，最大的坑）

builtin 把驱动初始化从"用户态 insmod"提前到了 initcall，撞上三个时序问题：

| 轮次 | 现象 | 根因 |
|---|---|---|
| 1 | `0.34s` `set power on fail`，无 wlan0 | `device_initcall` 早于 PMIC 稳压器 / sunxi-rfkill(~3.1s) / mmc2 枚举 |
| 2 | 改 `late_initcall` + 固件塞进 initramfs：供电✓、SDIO probe✓、固件 md5✓、`phy0` 注册✓，**但随后 `/init` 卡死，rootfs 永不挂载** | WiFi 在 initramfs 阶段"活着"与 `/init` 冲突（四轮对照实验的唯一变量） |
| 3 | ✅ **异步延迟初始化** | 见下 |

**最终方案**（`scripts/vendor-aic8800.sh` 里的 `aicv_wifi_init_thread`）：

```
late_initcall 只 kthread_run 一个 "aic8800_init" 线程就立即返回（启动零阻塞）
  └─ 线程轮询 CONFIG_AIC_FW_PATH 目录是否可见（= switch_root 完成的天然信号）
       └─ 可见后调 rwnx_mod_init()  →  固件从真 rootfs 读，一次成功
```

配套细节：`rwnx_mod_init` 必须**去掉 `__init` 标记**（线程在 initmem 释放后运行；
其调用链已逐个核实无 `__init`）。

**核心认知（值得记住）**：initcall 里做任何"等 rootfs"的阻塞都是自杀——
rootfs 由 initramfs 的用户态 `/init` 挂载，而 `/init` 要等所有 initcall 结束才开始。
第 2 轮的"轮询重试"补丁就是这么把启动从 7.6s 拖到 31s 的。

**附带教训（initramfs 多段拼接）**：第 2 轮曾把固件 cpio **追加在 initrd 尾部**，
内核报 `Initramfs unpacking failed: invalid magic at start of compressed archive`——
`unpack_to_rootfs()` 要求 cpio 段起始 **4 字节对齐**（`if (*buf == '0' && !(this_header & 3))`），
而 gzip 段结束点 `46808279 % 4 = 3` 不对齐 → 追加段被当垃圾丢弃。
**正确做法是前置**（`fw.cpio + 原 initrd`，microcode 标准布局，cpio 工具输出天然 512 对齐）。
（最终方案不再需要动 initrd，但这条经验对任何 initramfs 拼接都适用。）

### 第四步：OpenWrt 用户态把 AP 拉起来（两个真坑 + 一个假坑）

内核侧通了之后，`uci`/netifd 仍起不了 AP。排查结论：

**假坑：`command failed: Not supported (-95)`**
来自 `mac80211.sh` 的 `setup_phy()` 用 `system()` 调的
`iw phy phy0 set antenna 0xffffffff 0xffffffff`——fullmac 驱动没实现 `.set_antenna`。
**非致命**（返回值被忽略），一度被误判为根因。

**假坑 2：`vif_radio_mask`**
`/usr/share/hostap/common.uc` 的 `wdev_create()` 会发 `NL80211_ATTR_VIF_RADIO_MASK`
（Wi-Fi 7 多射频属性，内核 6.15+ 才有；我们 6.6 的 `nl80211.h` 里 grep 不到）。
看着像版本代差，但**去掉后依旧失败**，不是致命原因。

**真坑：wpad 降权后 hostapd 不注册 ubus 对象** ← 致命

```
/usr/share/hostap/common.uc  →  hostapd.uc:601
    if (!global.ubus.list('hostapd'))
            system('ubus wait_for hostapd');     ← 永久阻塞在这
```

`ubus list` 里没有 `hostapd` 对象 → wifi-scripts 死等 → radio 永久 `pending`、
接口不创建、`/var/run/hostapd-*.conf` 不生成、netifd 每 30s  tear down/Starting 空转。

隔离实验（决定性）：

| hostapd 运行方式 | 用户 | ubus 对象 |
|---|---|---|
| 直接跑 / procd 不降权 | root | ✅ `hostapd` `hostapd-auth` `hostapd.phy0-ap0` |
| procd 降权（无 jail） | network | ❌ 无 |
| procd 降权 + ujail（默认） | network | ❌ 无 |

→ **与 jail 无关，纯粹是降权到 `network` 用户导致**（`chmod 1777 /var/run`、
给 `wpad.json` 加 `CAP_DAC_OVERRIDE` 都无效）。

**修法**（一行，已板上验证）：让 `/etc/init.d/wpad` 里的 jail 条件为假即可
（`[ -x /sbin/ujail -a -e /etc/capabilities/wpad.json ]`）：

```bash
mv /etc/capabilities/wpad.json /etc/capabilities/wpad.json.disabled
```

**另一个必踩点：`wifi config` 自动生成的频段是错的**
本芯片 Band 1（2.4G）只有 HT/VHT、**无 HE**，且是 2.4G 单频；
自动生成却写 `band 5g / channel 36 / HE80`（生成时 `iwinfo` 缺失导致误判）。
必须手工改成：

```bash
uci set wireless.radio0.band=2g
uci set wireless.radio0.channel=6
uci set wireless.radio0.htmode=HT20
```

### 最终验收记录（冷启动、零人工干预）

```
up 2 min
[    6.145424] aic8800: rootfs ready (~2s), init wifi      ← 异步线程只等了 2s
[    8.168293] ieee80211 phy0: HT supp 1, VHT supp 1, HE supp 1
phy0-ap0: <BROADCAST,MULTICAST,UP,LOWER_UP> master br-lan state UP
ubus network.wireless: "up": true, "pending": false
iw dev: phy0-ap0  type AP  ssid ImmortalWrt  channel 6 (2437 MHz), 20 MHz
brctl show br-lan: eth0 + phy0-ap0
hostapd: phy0-ap0: AP-ENABLED
lsmod | grep -c aic  →  0                                   ← 真 builtin
```

开机约 8 秒 WiFi AP 自动就绪并桥接进 LAN。

## 6. 待验证问题清单

| # | 问题 | 状态/结论 |
|---|---|---|
| 1 | 固件目录/加载方式 | ✅ D80 子目录 + filp_open 直读（§5 记录） |
| 2 | btlpm（蓝牙）是否必须 | ✅ 跳过 btlpm WiFi 正常工作；btlpm 未编进 builtin 内核 |
| 3 | hotplug/kmodloader 自动加载 | ✅ 不再需要——驱动 builtin，开机即在场 |
| 4 | AIC_FW_PATH 指向 | ✅ `/lib/firmware/aic8800_fw/SDIO/aic8800D80`（已固化在 fragment） |
| 5 | modinfo 声明的固件 | ✅ 实际只读 `fmacfw_8800d80_u02.bin` 等 D80 文件，无 request_firmware |
| 6 | builtin 内核板上复验 | ✅ 冷启动零干预，AP-ENABLED + 桥接 br-lan（§5 验收记录） |
| 7 | uci/netifd `-95` | ✅ 假坑：`iw set antenna` 的噪音，非致命。真坑是 wpad 降权后 hostapd 不注册 ubus 对象（§5 第四步） |
| 8 | initcall 里能否等 rootfs | ❌ 不能——rootfs 由 initramfs 的 /init 挂载，而 /init 等 initcall 结束；必须异步线程 |
| 9 | initrd 多段拼接 | ✅ 固件段必须**前置**（追加在 gzip 段尾部会因 4 字节不对齐被内核丢弃） |


## 7. image 仓（radxa-a5e-openwrt）待办

内核侧已全部搞定，镜像侧还需要 4 件事：

1. **固件分发**：把 `aic8800_fw/SDIO/aic8800D80/`（15 个文件，~1.7MB；来源 Radxa
   Debian rootfs 的 `/usr/lib/firmware/`）拷到 rootfs 的 `/lib/firmware/aic8800_fw/SDIO/`。
   ⚠️ 路径必须与 fragment 里的 `CONFIG_AIC_FW_PATH` 完全一致（驱动 filp_open 直读，
   不走 request_firmware，路径错了就是静默失败）。
2. **禁用 wpad 降权**：`/etc/capabilities/wpad.json` 改名或删除（§5 第四步），
   否则 hostapd 不注册 ubus 对象、AP 永远起不来。
3. **预置 `/etc/config/wireless`**：`band=2g channel=6 htmode=HT20`（别让
   `wifi config` 猜成 5g/HE80），或至少在文档里写明首次需手工改。
4. **补两个用户态包**：`iw` + `wifi-scripts`（后者提供 `/sbin/wifi`，25.12 新拆包；
   缺了它 `wifi config`/`wifi up` 全部 `not found`）。
5. **内核资产**：直接用 kernel 仓 release 的 `vmlinuz` + `modules-and-dtb.tar`；
   模块树里**不会**有 `aic*.ko`（已 builtin），这是正常的，不要当成缺失。
   `initrd` **无需任何改动**。

## 8. 文档同步

主项目《OpenWrt-A5E-制作记录.md》展望节的"WiFi 调通"一项可以关闭，
并补记 §5 第三步（initcall 时序）与第四步（wpad 降权）两个坑。
