# A5E WiFi 驱动（AIC8800）调研与集成方案

> 状态：**驱动已 builtin 化并本地构建验证通过**（2026-10-06，feature/aic8800-builtin）。
> 板上验证：模块方案已点亮（scan/AP 均通，见 §5 第一步记录）；builtin 内核待烧录验收。
> bridge/firewall4 早前已根治（builtin）并烧录验收。
> 相关：[A5E-内核编译-记录.md](A5E-内核编译-记录.md)（内核流水线）、
> [OpenWrt镜像-定制内核替换.md](OpenWrt镜像-定制内核替换.md)（镜像替换流程）、
> 主项目《OpenWrt-A5E-制作记录.md》坑 8 与展望节。

## 0. TL;DR

| 项 | 结论 |
|---|---|
| 芯片 | AIC8800（板载，SDIO 接口，WiFi6 单天线） |
| 驱动形态 | **DKMS 外置包**（`aic8800-sdio 5.0+git20260123`），不在内核源码树内 |
| 内核 ABI | Radxa 预编译 `.ko` 的 vermagic = `6.6.98-1-aw2607`，与本仓库内核**完全兼容，可直接复用** |
| 固件 | 必须随镜像分发（`request_firmware()` 运行时加载），约 300KB+ |
| 当前镜像 | **无驱动、无固件**，WiFi 完全不可用 |
| 推荐路线 | ✅ ① 模块手动注入板上验证通过 → ✅ ② builtin 化完成（vendor 进内核树） |

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

## 4. 镜像缺口（内核侧已清零，只剩固件分发）

对照本仓库产物与 image 仓（`radxa-a5e-openwrt`）流水线实测：

1. ~~kernel 产物里没有 aic8800 模块~~ **✅ 已根治**：驱动整体 builtin，
   模块目录无任何 `aic*.ko`（bsp/fdrv 进 vmlinux）；
2. ~~cfg80211/mac80211 是 `.ko` 模块~~ **✅ 已根治**：随 fragment `=y` builtin；
3. **⬜ 镜像里没有固件**——`custom/rootfs` 与 armsr rootfs 的 `/lib/firmware/` 为空，
   需要 image 仓把 `aic8800_fw/SDIO/aic8800D80/` 拷进 `/lib/firmware/`
   （板上实测驱动读的是 `CONFIG_AIC_FW_PATH` 目录下的
   `fmacfw_8800d80_u02.bin` 等，见 §5 记录）。

用户态**无缺口**：armsr rootfs 自带 `wpad`/`hostapd`/`wpa_supplicant`、
`iwinfo` 库与 netifd 无线支持；缺 `iw` CLI（调试可选，可用 `iwinfo` 替代）。
驱动起来后 `/etc/config/wireless` 由 uci 首次生成。

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

### 第二步：根治 ✅ 已完成（走了方案 B 的改进版）

按 §3.2 落地：vendor 进内核树 builtin（方案 B），但用**板上验证过的 DKMS 源码**
而非 bsp 副本，并用符号隔离 + 54 个内部符号改名解决双模块私有副本的 builtin
链接障碍。本地全量构建 + verify.sh 全绿。

**剩余工作**：
1. 用新内核 + 固件组装镜像烧录，板上复验（wlan0 应开机自动出现，无需任何 insmod）；
2. image 仓（radxa-a5e-openwrt）加固件分发步骤（`aic8800_fw/SDIO/aic8800D80/` →
   `/lib/firmware/`）；aic8800 模块注入步骤**不再需要**；
3. uci/netifd `-95` 问题单独排查（见 §5 清单最后一项）。

### 文档同步

验证结论（固件目录、模块加载顺序、hostapd 配置）回填本文档 §2.3 与
主项目《OpenWrt-A5E-制作记录.md》展望节。

## 6. 待验证问题清单

| # | 问题 | 状态/结论 |
|---|---|---|
| 1 | 固件目录/加载方式 | ✅ D80 子目录 + filp_open 直读（§5 记录） |
| 2 | btlpm（蓝牙）是否必须 | ✅ 跳过 btlpm WiFi 正常工作；btlpm 未编进 builtin 内核 |
| 3 | hotplug/kmodloader 自动加载 | ✅ 不再需要——驱动 builtin，开机即在场 |
| 4 | AIC_FW_PATH 指向 | ✅ `/lib/firmware/aic8800_fw/SDIO/aic8800D80`（已固化在 fragment） |
| 5 | modinfo 声明的固件 | ✅ 实际只读 `fmacfw_8800d80_u02.bin` 等 D80 文件，无 request_firmware |
| 6 | builtin 内核板上复验（wlan0 自动出现、hostapd 可用） | ⬜ 待烧录新镜像验证 |
| 7 | uci/netifd `wifi up` 的 `-95`（fullmac 兼容） | ⬜ 待排查（不影响手工 hostapd） |
