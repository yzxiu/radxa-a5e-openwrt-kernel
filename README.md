# Radxa Cubie A5E OpenWrt 定制内核

针对 [Radxa Cubie A5E](https://www.radxa.com/products/cubie/a5e.html)（Allwinner A527 / sun55iw3）
在 OpenWrt/ImmortalWrt 上运行所需的最小定制内核构建流水线。

**只做一件事**：在 [yzxiu/linux-aw2607](https://github.com/yzxiu/linux-aw2607)
（[radxa-pkg/linux-aw2607](https://github.com/radxa-pkg/linux-aw2607) 的 fork，锁定构建逻辑与 submodule pin
避免上游改动打挂 CI）的默认内核配置之上，追加一小撮 `=y` 让 **bridge / firewall4 / tproxy** 相关子系统
直接进 vmlinux，避开 OpenWrt 的 kmodloader 对 aw2607 内核模块格式的依赖解析失灵问题
（现象：`modprobe bridge` exit 255，`firewall4` active with no instances，详见主项目文档）。

## 目录结构

```
.
├── .github/workflows/build.yml   # Actions 主入口
├── configs/
│   └── a5e-openwrt.config        # 内核 fragment：我们额外要求 builtin 的顶层 CONFIG
├── patches/                      # 可选：本仓库自己的额外 patch（若有）
├── scripts/
│   ├── build.sh                  # clone + patch + fragment + make build
│   ├── post-process.sh           # deb → .ko.xz→.ko + modules.dep 修 + 提取未压缩 Image
│   └── verify.sh                 # 校验关键模块是否真的进 vmlinux
└── README.md
```

## 定制哲学

- **不 fork、不侵入上游**：通过 `KERNEL_DEFCONFIG="defconfig radxa.config a5e-openwrt.config"`
  让 Kbuild 在 `radxa.config` 之后**追加**我们的 fragment，不修改 `radxa.config` 一行。
- **只列顶层**：fragment 里只写必需的顶层 CONFIG；子依赖（LLC/STP/NETFILTER_NETLINK/
  NF_TABLES_INET 等）由内核 Kconfig 的 `select` 自动带出。若运行时报缺某表达式，
  **只加一行 `CONFIG_XXX=y`**，其它不动。
- **产物即开即用**：Actions 上传的 artifact 已经把 `.ko.xz` 展开成 `.ko`、修好
  `modules.dep` 里的路径、删了 `.bin` 缓存、并额外提供**未压缩** `vmlinuz`
  （deb 里那个是 gzip，U-Boot extlinux 加载不了）。

## 本地构建（一键）

前置（Ubuntu 22.04 / 24.04）：

```bash
sudo dpkg --add-architecture arm64
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  build-essential git ca-certificates curl xz-utils \
  bc bison flex rsync cpio kmod \
  libssl-dev libncurses-dev libelf-dev \
  dpkg-dev debhelper devscripts fakeroot quilt \
  crossbuild-essential-arm64 qemu-user-static binfmt-support
sudo apt-get install -y libssl-dev:arm64
```

跑：

```bash
./scripts/build.sh \
  && ./scripts/post-process.sh \
  && ./scripts/verify.sh
```

产物在 `out/`：

```
out/
├── linux-image-6.6.98-1-aw2607_6.6.98-1_arm64.deb
├── linux-headers-6.6.98-1-aw2607_6.6.98-1_arm64.deb
├── linux-libc-dev_6.6.98-1_arm64.deb
├── vmlinuz                                   # 未压缩 ARM64 Image（~27MB）
├── root/
│   ├── lib/modules/6.6.98-1-aw2607/          # 已展开 .ko、已修 modules.dep、已删 .bin
│   └── usr/lib/linux-image-6.6.98-1-aw2607/  # dtb
└── sha256sums.txt
```

## GitHub Actions

**手动触发**：Actions 页 → Build A5E OpenWrt Kernel → Run workflow → 可选填 `kernel_ref`
（默认 `main`；填 sha/branch/tag 会走完整 clone + checkout 而不是 shallow）。

**自动触发**：
- push 到 `main` 且改动了 `configs/**` / `patches/**` / `scripts/**` / workflow 文件

**Release 发布**（build 成功即发）：
- push main / dispatch → 滚动 **prerelease `dev-build`**（每次覆盖产物、`target` 移到最新 commit，下载它永远是最新 main 构建）
- 打 `v*` tag → **正式 release**（用 tag 名）

产物可从 Actions artifact（`a5e-kernel-<run>`）或 release 的 asset 下载：
`vmlinuz-*`、`modules-and-dtb.tar`（已处理好的 .ko + dtb）、`linux-image-*.deb`、`sha256sums.txt`、`BUILD_INFO.env`。

**环境/耗时**：job 跑在 `container: debian:bookworm`（同本地 devcontainer，避免 Ubuntu
24.04 的 deb822 源缺 arm64 URIs）；apt 强制 `ForceIPv4`（Actions 走 IPv6 拉不到源）；
全量编译 ~15-25 分钟，改 scripts/config 走增量（已编译 objects 有 `save-always` cache）。

## 已验证的下游集成

主项目 `radxa-a5e` 里 OpenWrt 拼装镜像：把 `out/vmlinuz` + `out/root/lib/modules/` +
`out/root/usr/lib/linux-image-*/` 用 fuse2fs 直接替换到 `owrt-a5e.img` 的 rootfs 分区
p3 里即可（分区 LBA 679936 / 488MB ext4）。参考 `docs/A5E-内核编译-记录.md` 第 7 节。

## 已知约束

- 目标内核版本跟随上游 `linux-aw2607`（当前 6.6.98-1-aw2607）；改内核字符串要改上游
  `debian/changelog`，本仓库不负责版本管理
- `KDEB_COMPRESS=xz` 是上游 Makefile.extra 硬编码，`.ko.xz → .ko` 只能在 post-process
  阶段处理，不能通过配置绕过
- `deb` 里的 `vmlinuz` 是 gzip 格式（Debian 打包惯例），U-Boot extlinux 需要**未压缩**
  Image —— 所以 post-process 从 `arch/arm64/boot/Image` 单独取
- host 工具（`extract-cert`/`fixdep` 等）：Makefile.extra 原本 `HOSTCC=$(CROSS_COMPILE)gcc`，
  Actions container 无 binfmt_misc 会 `Exec format error`。**build.sh 已自动 `sed` 成 `HOSTCC=gcc`**
  （host 工具用 host gcc），target 内核仍交叉编译。本地有 binfmt 时两种都行。

## Fragment 当前覆盖的 CONFIG（49 行）

> 完整以 `configs/a5e-openwrt.config` 为准；下列按组概略。

- **bridge**：`BRIDGE`, `BRIDGE_NETFILTER`（自动 select `LLC`/`STP`）
- **fw4 core**：`NF_TABLES`, `NF_CONNTRACK`, `NF_NAT`, `NF_NAT_MASQUERADE`, `NF_NAT_REDIRECT`
- **nft expressions**：`NFT_CT/LIMIT/LOG/MASQ/NAT/REDIR/REJECT/COMPAT/SOCKET/FLOW_OFFLOAD`
- **fib**：`NFT_FIB`(父) + `NFT_FIB_INET/IPV4/IPV6/NETDEV`
- **桥 netfilter**：`NF_TABLES_BRIDGE`(父 menuconfig) + `NFT_BRIDGE_META` + `NFT_BRIDGE_REJECT` + `NF_REJECT_IPV4/6`
- **透明代理**：`NFT_TPROXY` + `NF_TPROXY_IPV4/6` + `NF_SOCKET_IPV4/6` + `NF_DUP_IPV4/6/NETDEV`
- **iptables 兼容层**（xt_tproxy 依赖）：`NETFILTER_XTABLES` + `IP_NF_IPTABLES/IP6_NF_IPTABLES/IP_NF_NAT/IP_NF_MANGLE` + `NETFILTER_XT_TARGET_TPROXY/REDIRECT` + `NETFILTER_XT_MATCH_SOCKET`
- **支撑**：`NF_DEFRAG_IPV4/6`, `NF_LOG_SYSLOG`, `NF_FLOW_TABLE`, `NF_FLOW_TABLE_INET`

## 相关文档

- 主项目：`../../OpenWrt-A5E-制作记录.md`（坑 7 讲清了 bridge 为什么加载不了）
- 编译详细：`docs/A5E-内核编译-记录.md`（本 Actions 的前身调研 + 踩过的所有坑）
- 替换流程：`docs/OpenWrt镜像-定制内核替换.md`（新内核塞进 `owrt-a5e.img` 的可复用步骤）
- WiFi 驱动：`docs/A5E-WiFi驱动-AIC8800-调研.md`（AIC8800 DKMS 驱动结构、固件机制、集成路线图）

## License / 上游许可

本仓库只做配置/脚本包装，最终产物遵循上游 linux-aw2607 的许可证（GPL-2.0）。
