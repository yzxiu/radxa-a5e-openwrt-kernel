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
- 打 `v*` tag 会额外把产物 attach 到 GitHub Release

**预计耗时**：单跑一次全量 ~15-25 分钟（Actions 的 ubuntu-24.04 是 4 核）；
本地 16 核机器 ~8-10 分钟。

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
- host 工具（`extract-cert` 等）用交叉编译器编译（Makefile.extra 的 `HOSTCC=$(CROSS_COMPILE)gcc`），
  依赖 `libssl-dev:arm64`（**不是** `libssl-dev`）—— Actions 里已处理，本地跑要注意

## Fragment 当前覆盖的 CONFIG（36 行）

分组：
- **bridge**：`BRIDGE`, `BRIDGE_NETFILTER`（自动 select `LLC`/`STP`）
- **fw4 core**：`NF_TABLES`, `NF_CONNTRACK`, `NF_NAT`, `NF_NAT_MASQUERADE`, `NF_NAT_REDIRECT`
- **nft expressions**：`NFT_CT/LIMIT/LOG/MASQ/NAT/REDIR/REJECT/COMPAT/FIB_INET/SOCKET/FLOW_OFFLOAD`
- **bridge netfilter**：`NFT_BRIDGE_META`, `NFT_BRIDGE_REJECT`
- **透明代理（tproxy）**：`NFT_TPROXY`, `NF_TPROXY_IPV4/IPV6`, `NF_SOCKET_IPV4/IPV6`,
  `NETFILTER_XT_TARGET_TPROXY/REDIRECT`, `NETFILTER_XT_MATCH_SOCKET`, `NF_DUP_IPV4/IPV6/NETDEV`
- **支撑**：`NF_DEFRAG_IPV4/IPV6`, `NF_LOG_SYSLOG`, `NF_FLOW_TABLE`, `NF_FLOW_TABLE_INET`

## 相关文档

- 主项目：`../../OpenWrt-A5E-制作记录.md`（坑 7 讲清了 bridge 为什么加载不了）
- 编译详细：`docs/A5E-内核编译-记录.md`（本 Actions 的前身调研 + 踩过的所有坑）
- 替换流程：`docs/OpenWrt镜像-定制内核替换.md`（新内核塞进 `owrt-a5e.img` 的可复用步骤）

## License / 上游许可

本仓库只做配置/脚本包装，最终产物遵循上游 linux-aw2607 的许可证（GPL-2.0）。
