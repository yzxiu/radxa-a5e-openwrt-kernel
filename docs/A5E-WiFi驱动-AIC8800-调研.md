# A5E WiFi 驱动（AIC8800）调研与集成方案

> 状态：**调研完成，板上未验证**。bridge/firewall4 已根治（builtin）并烧录验收，WiFi 是下一个目标。
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
| 推荐路线 | ① 手动塞 `.ko`+固件板上验证 → ② 验证通过后 builtin 化（vendor 进内核树） |

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

## 3. 为什么不能像 bridge 一样"一行 CONFIG 编进内核"

| | bridge / firewall4 | aic8800 |
|---|---|---|
| 源码位置 | 内核源码树内（`net/bridge/` 等） | **树外**（DKMS 单独发包） |
| Kconfig 符号 | 现成（`CONFIG_BRIDGE` 等） | 内核树里**不存在** `CONFIG_AIC_*` |
| fragment 追加 | 直接生效 | 写了没东西可勾 |

**但 builtin 化本身是可行的**，关键依据：驱动 Makefile 已是标准
`obj-$(CONFIG_...)` 写法（AIC 官方给各芯片 BSP 的移植模板），天然支持 `=y`：

```makefile
# SDIO/driver_fw/driver/aic8800/Makefile
obj-$(CONFIG_AIC8800_BTLPM_SUPPORT) += aic8800_btlpm/
obj-$(CONFIG_AIC8800_WLAN_SUPPORT) += aic8800_fdrv/
obj-$(CONFIG_AIC_WLAN_SUPPORT)   += aic8800_bsp/
```

源码树里还自带 `for_Allwinner/A133/.../driver/net/wireless/aic8800/` 等
**in-tree 移植示例**，证明这条路线有官方先例。要做的只是：

1. `patches/` 加 patch：把 `driver/aic8800/`（3 个子目录）+ Kconfig 接线
   注入内核树 `drivers/net/wireless/aic8800/`；
2. fragment 追加 `CONFIG_AIC_WLAN_SUPPORT=y` 等（连同
   `CONFIG_CFG80211=y` / `CONFIG_MAC80211=y`——这两个是树内的，和 bridge 一样直接 builtin）。

**要认账的代价**：

- 固件**仍然要拷**（见 §2.2），builtin 不解决这个问题；
- fdrv 是 RivieraWaves 全 MAC 驱动，源码体量大，patch 塞新文件不优雅——
  实际做法：源码 tarball 走 release 附件/LFS，`build.sh` 下载后只 git apply 接线小 patch；
- 内核跟随上游 aw2607 升级时，这个 out-of-tree 驱动要跟着验（锁 6.6 期间风险低，
  但仓库性质从"配置包装"变成"养一个驱动移植"）。

## 4. 当前 OpenWrt 镜像的缺口（3 个）

对照本仓库 Actions 产物（`modules-and-dtb.tar`）与 image 仓
（`radxa-a5e-openwrt`）流水线实测：

1. **kernel-actions 产物里没有 aic8800 模块**——内核树不含此驱动，
   `lib/modules/<KVER>/updates/dkms/` 整个不存在，`modules.dep` 无 aic 条目；
2. **镜像里没有固件**——`custom/rootfs` 与 armsr rootfs 的 `/lib/firmware/` 为空；
3. **cfg80211/mac80211 是 `.ko` 模块**——已展开可手动加载，但走
   kmodloader/hotplug 自动加载有和 bridge 同源的依赖解析风险
   （《A5E-内核编译-记录.md》坑 8；文档内 TODO 已留 wireless builtin）。

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

板上验证清单：

- [ ] `insmod aic8800_bsp_sdio.ko && insmod aic8800_fdrv_sdio.ko`（顺序）
- [ ] `dmesg | grep -i -E "aic|firmware"`：确认 request 的固件名/路径，**修正 §2.3 的目录结论**
- [ ] `ip link` 出现 wlan 口；`iwinfo` 能扫到 AP
- [ ] uci 生成 `/etc/config/wireless`，hostapd 能起 AP / 连 STA

### 第二步：根治（验证通过后二选一）

- **方案 A（推荐，与"只做一件事"哲学兼容）**：image 仓加 `45-wireless.sh`——
  从 Debian 资产拷预编译 `.ko` + 固件 + depmod；kernel 仓 fragment 追加
  `CONFIG_CFG80211=y`/`CONFIG_MAC80211=y` 让依赖栈 builtin。
  改动小、零编译风险；aic8800 本体走 `/etc/modules.d/` 显式加载，不赌 hotplug。
- **方案 B（最彻底，维护成本高）**：按 §3 把 aic8800 vendor 进内核树 builtin，
  板上 `lsmod` 看不到它，和 bridge 同待遇。固件拷贝依旧需要（方案 A/B 都要）。

### 文档同步

验证结论（固件目录、模块加载顺序、hostapd 配置）回填本文档 §2.3 与
主项目《OpenWrt-A5E-制作记录.md》展望节。

## 6. 待验证问题清单

| # | 问题 | 验证方式 |
|---|---|---|
| 1 | 固件到底 request 哪个目录/哪些文件（§2.3 的硬编码路径 vs 裸名矛盾） | 第一步板上 `dmesg` |
| 2 | btlpm（蓝牙）是否必须加载 WiFi 才工作 | 第一步跳过 btlpm 试 |
| 3 | hotplug 自动加载修复后的 `.ko` 是否可靠（kmodloader 同源风险） | 第一步 reboot 后不手动 insmod 观察 |
| 4 | builtin 化时 `CONFIG_AIC_FW_PATH` 要不要改指向 `SDIO/aic8800/` | 由问题 1 的结论决定 |
| 5 | OpenWrt 下 `rwnx_settings.ini` 等 modinfo 声明的固件是否真被 request（可能只是声明） | dmesg request 日志 |
