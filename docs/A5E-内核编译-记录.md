# A5E 内核重编译记录（linux-aw2607）

> 目标：把 `CONFIG_BRIDGE` 从 `m` 改成 `y`（让 bridge 进 vmlinux），
> 并沉淀一条**可复现、可自动化（GitHub Actions）**的编译流水线。
> 这是主记录 `../../OpenWrt-A5E-制作记录.md` 坑 7 里 bridge 问题的**根治方案**；
> init.d 预加载作为回退方案保留。

本文所有路径基于**工作根** `$WS`（即你把 `radxa-a5e` 检出到的位置）。
开工前先设定一次，避免把本机绝对路径写进文档/脚本：

```bash
export WS="$HOME/work/radxa-a5e"   # ← 换成你自己的实际路径
```

> `$WS/radxa-a5e-openwrt-kernel` = 本仓库（kernel 定制）；`$WS/rsdk-src/rsdk` = rsdk 构建环境。

---

## 1. 背景：为什么非要重编内核

- 板子：Radxa Cubie A5E（Allwinner A527 / sun55iw3）
- OpenWrt 需要 `br-lan` → 需要内核的 bridge 功能
- Radxa 官方预编译内核（`linux-image-6.6.98-1-aw2607`）把 bridge 编成了**模块**（`CONFIG_BRIDGE=m`）
- 模块本身是 `.ko.xz`；OpenWrt 的 kmodloader 无 xz 支持 → 转 `.ko` 后仍然失败：
  - **`modprobe bridge` 一直 exit 255**（kmodloader 对 aw2607 模块格式的依赖解析 bug）
  - **`insmod llc → stp → bridge` 手动按顺序加载能成**
- 绕过方案：init.d 早期 `insmod`（主记录坑 7，见 `owrt-a5e.img.bak-initd`）
- **根治方案**：让 bridge 变 builtin，netifd 建桥时根本不需要 modprobe

---

## 2. 上游仓库结构

```
radxa-pkg/linux-aw2607 (main)
├── .gitmodules                    # 3 个 submodule
├── Makefile / Makefile.extra      # rsdk infra-package 自动生成的构建入口
├── debian/
│   ├── changelog                  # 版本字符串（决定 LOCALVERSION / KERNELRELEASE / KDEB_PKGVERSION）
│   ├── patches/series             # 4 个 patch
│   └── patches/linux/
│       ├── 0001-feat-Radxa-common-kernel-config.patch    # 创建 src/arch/arm64/configs/radxa.config (~1118 行)
│       ├── 0002-feat-Radxa-custom-kernel-config.patch    # 创建 src/arch/arm64/configs/radxa_custom.config
│       ├── 0003-fix-use-the-correct-header-path.patch    # 修 bsp/drivers/… 里的 include 路径
│       └── 0004-fix-add-device-tree.patch                # 把 a5e dtb 加入 arch/arm64/boot/dts/allwinner/Makefile
├── src         (submodule)        # 内核源码：radxa/kernel @ allwinner-aiot-linux-6.6
├── bsp         (submodule)        # allwinner-bsp @ cubie-aiot-v1.5.0（BSP 驱动源码；src/bsp 是指向此目录的 symlink）
└── device-a527 (submodule)        # allwinner-device @ device-a527-v1.5.0
```

关键点：

- **构建入口**：`make build`（顶层 Makefile + Makefile.extra）
  - 流程：`pre_build → build-defconfig → build-all → build-bindeb → post_build`
  - `KERNEL_DEFCONFIG = defconfig radxa.config`（Kbuild 的 `make <defconfig> <fragment>` merge_config 语义）
  - `build-bindeb` 里：`make all` → `make bindeb-pkg`，产物 `mv linux-*_arm64.deb ../`（**落到仓库的上一级目录**，不是仓库根！）
- **LOCALVERSION / KERNELRELEASE**：由 `dpkg-parsechangelog -S Version` 决定 → `6.6.98-1` 拼上 `-aw2607` → `6.6.98-1-aw2607`。改内核版本字符串要改 `debian/changelog`。
- **KDEB_COMPRESS = xz**：deb 里的 `.ko` 会被压成 `.ko.xz`（OpenWrt 用不了，见 §6）。
- **`src/bsp` 是符号链接**指向 `../bsp`：patch 处理要绕开 `git apply` 的 "beyond a symbolic link" 限制（见 §4.2）。

`.gitmodules` 内容（备查）：

```
[submodule "bsp"]
    path = bsp
    url  = https://github.com/radxa/allwinner-bsp
    branch = cubie-aiot-v1.5.0
[submodule "device-a527"]
    path = device-a527
    url  = https://github.com/radxa/allwinner-device
    branch = device-a527-v1.5.0
[submodule "src"]
    path = src
    url  = https://github.com/radxa/kernel
    branch = allwinner-aiot-linux-6.6
```

---

## 3. 构建环境准备

**runner 需求**：x86_64 Linux 就够（纯交叉编译，不需要 KVM / ARM runner）。Ubuntu 22.04 / 24.04、GitHub Actions 的 `ubuntu-latest` 均可。

```bash
sudo dpkg --add-architecture arm64          # ← 关键：装 libssl-dev:arm64 之前必须
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
    build-essential git ca-certificates curl xz-utils \
    bc bison flex rsync cpio kmod \
    libssl-dev libncurses-dev libelf-dev \
    dpkg-dev debhelper devscripts fakeroot quilt \
    crossbuild-essential-arm64 \
    qemu-user-static binfmt-support

# host 工具（extract-cert 等）用 aarch64-linux-gnu-gcc 编译，需要 arm64 版 openssl 头
sudo apt-get install -y libssl-dev:arm64
```

**为什么还要 `libssl-dev:arm64`** —— 见 §5 坑 C。

工具链检查：

```bash
aarch64-linux-gnu-gcc --version   # 应输出 (Ubuntu …) 12.x
```

---

## 4. 完整构建步骤

### 4.1 克隆（浅）

```bash
cd $WS
rm -rf linux-aw2607-build
git clone --recursive --depth 1 --shallow-submodules \
    https://github.com/radxa-pkg/linux-aw2607.git linux-aw2607-build
cd linux-aw2607-build
# 实测 2.6 GB（浅 clone + shallow submodule 后），GitHub Actions 里加 cache 明显提速
```

### 4.2 应用 debian patch —— **两种路径前缀，不能一刀切**

四个 patch 的 diff 路径**前缀并不统一**：

| Patch | 第一行 `diff --git` 的路径 | 相对谁 | 在哪个目录用几 p |
|-------|--------------------------|--------|-----------------|
| 0001  | `a/src/arch/arm64/configs/radxa.config` | 仓库根 | `cd src && git apply -p2` |
| 0002  | `a/src/arch/arm64/configs/radxa_custom.config` | 仓库根 | `cd src && git apply -p2` |
| 0003  | `a/bsp/drivers/g2d/g2d_trace.h`         | 仓库根 | **仓库顶层 `git apply -p1`** |
| 0004  | `a/src/arch/arm64/boot/dts/allwinner/Makefile` | 仓库根 | `cd src && git apply -p2` |

**推荐脚本**（简单统一：全部在仓库顶层用 `-p1`，效果相同）：

```bash
# 全部从顶层用 -p1 应用
git apply -p1 debian/patches/linux/0001-feat-Radxa-common-kernel-config.patch
git apply -p1 debian/patches/linux/0002-feat-Radxa-custom-kernel-config.patch
git apply -p1 debian/patches/linux/0003-fix-use-the-correct-header-path.patch
git apply -p1 debian/patches/linux/0004-fix-add-device-tree.patch
```

> 我实际执行时先在 `src/` 用 `-p2` 应用了 0001/0002/0004（成功），
> 0003 因 `src/bsp` 是 symlink 报了 `beyond a symbolic link`；
> 改到仓库**顶层**用 `-p1` 就成功了（见 §5 坑 B）。
> **两种做法都可行； Actions 里建议统一在顶层 `-p1`。**

验证：

```bash
# 三个都应有输出
ls -l src/arch/arm64/configs/radxa.config          # ~25 KB
grep -n "TRACE_INCLUDE_PATH" bsp/drivers/g2d/g2d_trace.h
# 期望：#define TRACE_INCLUDE_PATH ../../bsp/drivers/g2d
grep "sun55i-a527-cubie-a5e" src/arch/arm64/boot/dts/allwinner/Makefile
```

### 4.3 修改内核配置（本例：bridge builtin）

**只改一行，`CONFIG_BRIDGE=m → y`**：

```bash
CFG=src/arch/arm64/configs/radxa.config
sed -i 's/^CONFIG_BRIDGE=m$/CONFIG_BRIDGE=y/'          "$CFG"
sed -i 's/^CONFIG_BRIDGE_NETFILTER=m$/CONFIG_BRIDGE_NETFILTER=y/' "$CFG"
```

**为什么不用单独设 `CONFIG_STP=y` / `CONFIG_LLC=y`**：
`net/bridge/Kconfig` 里 `CONFIG_BRIDGE` 通过 `select` 拉进 `LLC` 和 `STP`。
`make defconfig radxa.config` 后 `.config` 里会自动出现 `CONFIG_STP=y` / `CONFIG_LLC=y`（实测确认）。

**顺带 `CONFIG_BRIDGE_NETFILTER=y`**：不改成 `y` 的话它是 `.ko`，走 modprobe（又是坑 7 那类问题）；直接 builtin 更干净。

改完后可以本地快速检查：

```bash
grep -E "^CONFIG_BRIDGE=|^CONFIG_BRIDGE_NETFILTER=|^CONFIG_STP=|^CONFIG_LLC=" "$CFG"
```

### 4.4 编译

**在 linux-aw2607-build 顶层**：

```bash
make build           # 全流程（defconfig + all + bindeb-pkg + mv）
```

`make build` 内部（Makefile.extra 展开）：

```
make -C src ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
     KDEB_COMPRESS=xz DPKG_FLAGS=-d \
     LOCALVERSION=-6.6.98-1-aw2607 KERNELRELEASE=6.6.98-1-aw2607 \
     KDEB_PKGVERSION=6.6.98-1 \
     defconfig radxa.config
make -C src ... all
make -C src ... bindeb-pkg
mv linux-*_arm64.deb linux-upstream*_arm64.changes linux-upstream*_arm64.buildinfo ../
```

> **注意 `mv ../`**：deb 会落到 linux-aw2607-build 的**上一级目录**（例如我们工作流里是 `rsdk-src/`）。找 deb 时别在仓库根目录找。

**耗时**（实测，x86_64 16 核 + 交叉编译）：约 8–10 分钟。
GitHub Actions 4 核 `ubuntu-latest` 预计 15–25 分钟。

**产物**（示例）：

```
../linux-image-6.6.98-1-aw2607_6.6.98-1_arm64.deb     ~23 MB
../linux-headers-6.6.98-1-aw2607_6.6.98-1_arm64.deb   ~8.2 MB
../linux-libc-dev_6.6.98-1_arm64.deb                  ~1.3 MB
../linux-upstream_6.6.98-1_arm64.changes
../linux-upstream_6.6.98-1_arm64.buildinfo
```

### 4.5 快速验证：bridge 真的进 vmlinux 了

```bash
# 1) .config
grep -E "^CONFIG_BRIDGE=|^CONFIG_STP=|^CONFIG_LLC=|^CONFIG_BRIDGE_NETFILTER=" \
     src/.config
# 期望全部 =y

# 2) deb 里 modules.builtin 列出 bridge
dpkg-deb -x ../linux-image-6.6.98-1-aw2607_*.deb /tmp/ki
grep -E "bridge|llc/llc|802/stp" \
     /tmp/ki/lib/modules/6.6.98-1-aw2607/modules.builtin
# 期望：
#   kernel/net/llc/llc.ko
#   kernel/net/802/stp.ko
#   kernel/net/bridge/bridge.ko
#   kernel/net/bridge/br_netfilter.ko

# 3) bridge.ko 应该"消失"（已 builtin）
find /tmp/ki/lib/modules/6.6.98-1-aw2607 -name "bridge.ko*" -o -name "stp.ko*" -o -name "llc.ko*"
# 期望：空
```

---

## 5. 一定会踩到的坑（Actions 自动化尤其要写死这几处）

### 坑 A：deb 里的 `vmlinuz-…` 是 gzip，U-Boot extlinux **加载不了**

`make bindeb-pkg` 打的 deb，`/boot/vmlinuz-6.6.98-1-aw2607` 是 **gzip 压缩**（≈10 MB）。
U-Boot 的 extlinux 只吃**未压缩的 ARM64 Image**（Radxa 官方 deb 里那个 24 MB 未压缩就是特意这么打的）。

**正确取法**：从内核 build 目录直接拿未压缩 Image：

```bash
src/arch/arm64/boot/Image       # 未压缩，~27 MB，就是它
```

或者等价：`gunzip -c deb里的 vmlinuz > Image`。

`file` 检查：

```bash
file src/arch/arm64/boot/Image
# Linux kernel ARM64 boot executable Image, little-endian, 4K pages   ← 对
file deb里的 vmlinuz
# gzip compressed data ...                                              ← 错
```

### 坑 B：`src/bsp` 是符号链接，`git apply` 在 `src/` 里拒绝穿过 symlink 修改

`git apply -p1` 在 `src/` 里跑 0003 时报：

```
error: affected file 'bsp/drivers/g2d/g2d_trace.h' is beyond a symbolic link
```

因为 `src/bsp -> ../bsp`（真实目录在仓库顶层）。git 拒绝修改 symlink 后面的文件（防止越权）。

**解决**：**站在仓库顶层用 `-p1` 应用 0003**（路径直接落到真实的 `bsp/…`）。

```bash
cd linux-aw2607-build        # 顶层
git apply -p1 debian/patches/linux/0003-fix-use-the-correct-header-path.patch
```

（`patch -p1 --follow-symlinks` 也能绕过，但 patch 命令对 git 二进制 patch 支持差，不推荐混用。）

### 坑 C：`extract-cert` 编译失败：`fatal error: openssl/opensslconf.h: No such file or directory`

`Makefile.extra` 里 `HOSTCC=$(CROSS_COMPILE)gcc` —— **host 工具也是用 aarch64 交叉编译器** 编出来的（跑的时候靠 `qemu-user-static` + binfmt 转译）。所以 host 工具依赖的头文件必须是 **arm64 版**：

```bash
sudo dpkg --add-architecture arm64
sudo apt-get install -y libssl-dev:arm64
```

`libssl-dev:arm64` 里的 `opensslconf.h` 落在 `/usr/include/aarch64-linux-gnu/openssl/`，正是 `aarch64-linux-gnu-gcc` 的头搜索路径。

如果只装 `libssl-dev`（amd64），头在 `/usr/include/x86_64-linux-gnu/openssl/`，交叉编译器找不到。

### 坑 D：新 deb 里的模块**仍然是 `.ko.xz`**

Radxa 的 `KDEB_COMPRESS="xz"` 决定了 deb 打包压缩。
OpenWrt 的 kmodloader/busybox 无 xz 解压 → 必须批量转 `.ko`（详见 §6）。

### 坑 E：（好消息）`modules.dep` 里 builtin 的依赖会被自动剥离

内核 depmod 在生成 `modules.dep` 时**已经处理了 builtin**：
比如 `nft_meta_bridge.ko` 的依赖列表里不会包含 `bridge.ko`（因为已 builtin，depmod 自动跳过）。

所以不需要额外 sed 移除对 bridge/stp/llc 的依赖引用 —— **改一行 config 就够了**。

---

## 6. 产物后处理（把 deb 变成能装进 OpenWrt 的东西）

### 6.1 提取 deb

```bash
dpkg-deb -x ../linux-image-6.6.98-1-aw2607_6.6.98-1_arm64.deb new-kernel/
```

### 6.2 `.ko.xz → .ko` 批量解压 + 修 `modules.dep`

```bash
KVER=6.6.98-1-aw2607
cd new-kernel/lib/modules/$KVER

# 1. 解压所有 .ko.xz → .ko
find . -name "*.ko.xz" -print0 | while IFS= read -r -d '' f; do
    xz -dc "$f" > "${f%.xz}" && rm -f "$f"
done
# 实测：882 个 .ko.xz → 882 个 .ko

# 2. 元数据里 .ko.xz 路径 sed 成 .ko
for m in modules.dep modules.alias modules.symbols modules.softdep \
         modules.devname modules.order modules.builtin.modinfo; do
    [ -f "$m" ] && sed -i 's/\.ko\.xz/.ko/g' "$m"
done

# 3. 删除 .bin 缓存（强制 kmodloader 读文本）
rm -f *.bin
```

### 6.3 校验依赖闭环

遍历 `modules.dep` 里所有依赖路径，确认对应文件真实存在（避免加载时 `ENOENT`）：

```bash
cd new-kernel/lib/modules/$KVER
missing=0
while IFS= read -r line; do
    deps=${line#*:}
    for d in $deps; do
        [ ! -e "$d" ] && { echo "MISS: $d"; missing=$((missing+1)); }
    done
done < modules.dep
echo "缺失依赖总数: $missing"       # 期望：0
```

### 6.4 校验 builtin 生效

```bash
# 这 4 个必须出现在 modules.builtin
grep -E "bridge/|802/stp|llc/llc" modules.builtin
# kernel/net/llc/llc.ko
# kernel/net/802/stp.ko
# kernel/net/bridge/bridge.ko
# kernel/net/bridge/br_netfilter.ko

# 这 4 个 .ko 文件必须"消失"（已进 vmlinux）
for m in net/bridge/bridge net/802/stp net/llc/llc net/bridge/br_netfilter; do
    [ -e "kernel/$m.ko" ] && echo "✗ 意外存在: $m.ko" || echo "✓ builtin: $m.ko"
done
```

---

## 7. 装到 OpenWrt 拼装镜像（可选，本文的重点在编译产物）

`owrt-a5e.img`（820 MB，GPT）里 p3=rootfs（LBA 679936，488 MB ext4）。免 root 用 **fuse2fs**：

```bash
# 1. 提取 p3
dd if=owrt-a5e.img of=/tmp/rp.img bs=512 skip=679936 count=998433 status=none

# 2. fuse2fs 挂载
mkdir -p /tmp/mnt-rp
fuse2fs /tmp/rp.img /tmp/mnt-rp

# 3. 替换内核文件
KVER=6.6.98-1-aw2607
cp src/arch/arm64/boot/Image /tmp/mnt-rp/boot/vmlinuz-$KVER

rm -rf /tmp/mnt-rp/lib/modules/$KVER
mkdir -p /tmp/mnt-rp/lib/modules/$KVER
cp -a new-kernel/lib/modules/$KVER/. /tmp/mnt-rp/lib/modules/$KVER/

rm -rf /tmp/mnt-rp/usr/lib/linux-image-$KVER
mkdir -p /tmp/mnt-rp/usr/lib/linux-image-$KVER
cp -a new-kernel/usr/lib/linux-image-$KVER/. /tmp/mnt-rp/usr/lib/linux-image-$KVER/

# 4. 删除 init.d 备用方案（不再需要）
rm -f /tmp/mnt-rp/etc/init.d/bridge-modules \
      /tmp/mnt-rp/etc/rc.d/S15bridge-modules

# 5. initrd 保留旧版即可（Debian initramfs 认识 UUID=；
#    即便里面还嵌了旧 bridge.ko.xz 加载失败也不影响 —— 内核已 builtin）

# 6. umount（容器里没 fusermount 时，kill 进程即可）
sync
pgrep -x fuse2fs | xargs -r kill
sleep 2

# 7. 回写镜像
dd if=/tmp/rp.img of=owrt-a5e.img bs=512 seek=679936 conv=notrunc status=none
sha256sum owrt-a5e.img | tee owrt-a5e.img.sha256
```

（旧 `owrt-a5e.img.bak-initd` 保留了 init.d 回退方案，随时可切。）

---

## 8. GitHub Actions workflow 骨架（可直接落地）

**目标**：改一行 config 或 patch 就自动重编，产出 `vmlinuz` + 处理好的 `/lib/modules/` + `linux-image-*.deb`。

放到本仓库（比如 `radxa-a5e-kernel` fork 或 openwrt 侧的仓库）的 `.github/workflows/build-a5e-kernel.yml`：

```yaml
name: linux-aw2607 (bridge builtin)

on:
  workflow_dispatch:
  push:
    paths:
      - '.github/workflows/build-a5e-kernel.yml'
      - 'patches/**'                  # 我们自己的覆盖 patch（可选）
      - 'config-overrides/**'         # 我们自己的 config 覆盖（可选）
  schedule:
    - cron: '0 3 * * 1'               # 每周一 3:00 拉一次上游重编（可选）

jobs:
  build:
    runs-on: ubuntu-24.04
    timeout-minutes: 60
    steps:
      - name: checkout upstream linux-aw2607
        uses: actions/checkout@v4
        with:
          repository: radxa-pkg/linux-aw2607
          submodules: recursive
          fetch-depth: 1
          path: kernel

      - name: apt deps
        run: |
          sudo dpkg --add-architecture arm64
          sudo apt-get update
          sudo apt-get install -y --no-install-recommends \
            build-essential xz-utils bc bison flex rsync cpio kmod \
            libssl-dev libncurses-dev libelf-dev \
            dpkg-dev debhelper devscripts fakeroot \
            crossbuild-essential-arm64 qemu-user-static binfmt-support
          sudo apt-get install -y libssl-dev:arm64

      - name: cache apt
        uses: actions/cache@v4
        with:
          path: /var/cache/apt
          key: apt-${{ runner.os }}-arm64-cross

      - name: apply debian patches (all -p1 from repo root)
        working-directory: kernel
        run: |
          for p in debian/patches/linux/000*.patch; do
            git apply -p1 "$p"
          done

      - name: overlay local patches (optional)
        working-directory: kernel
        if: hashFiles('../local-patches/*.patch') != ''
        run: |
          for p in ../local-patches/*.patch; do git apply -p1 "$p"; done

      - name: config override — bridge builtin
        working-directory: kernel
        run: |
          sed -i 's/^CONFIG_BRIDGE=m$/CONFIG_BRIDGE=y/' \
            src/arch/arm64/configs/radxa.config
          sed -i 's/^CONFIG_BRIDGE_NETFILTER=m$/CONFIG_BRIDGE_NETFILTER=y/' \
            src/arch/arm64/configs/radxa.config

      - name: cache kernel build objects
        uses: actions/cache@v4
        with:
          path: |
            kernel/src/*.o
            kernel/src/**/*.o
            kernel/src/.config
            kernel/src/include/config
            kernel/src/arch/arm64/include/asm
          key: kobj-${{ hashFiles('kernel/src/**', 'kernel/debian/patches/**', 'kernel/config/**') }}
          restore-keys: kobj-

      - name: build kernel deb
        working-directory: kernel
        run: make build

      - name: post-process (xz → .ko, drop .bin, extract plain Image)
        working-directory: kernel
        run: |
          set -eu
          KVER="$(dpkg-parsechangelog -S Version)-aw2607"
          mkdir -p work
          dpkg-deb -x ../linux-image-*.deb work/          # 注意：deb 在 kernel 的上一级
          pushd work/lib/modules/$KVER
            find . -name '*.ko.xz' -print0 | while IFS= read -r -d '' f; do
              xz -dc "$f" > "${f%.xz}" && rm -f "$f"
            done
            for m in modules.dep modules.alias modules.symbols modules.softdep \
                     modules.devname modules.order modules.builtin.modinfo; do
              [ -f "$m" ] && sed -i 's/\.ko\.xz/.ko/g' "$m"
            done
            rm -f *.bin
            # 校验：bridge 应在 modules.builtin 里，且 kernel/net/bridge/bridge.ko 应不存在
            grep -q '^kernel/net/bridge/bridge.ko$' modules.builtin
            test ! -e kernel/net/bridge/bridge.ko
          popd
          cp src/arch/arm64/boot/Image work/vmlinuz

      - name: upload artifact — kernel deb
        uses: actions/upload-artifact@v4
        with:
          name: linux-image-deb
          path: kernel/../linux-image-*.deb

      - name: upload artifact — vmlinuz + modules
        uses: actions/upload-artifact@v4
        with:
          name: a5e-kernel-prepared
          path: |
            kernel/work/vmlinuz
            kernel/work/lib/modules
            kernel/work/usr/lib/linux-image-*
```

**关键工程细节**：

- `dpkg --add-architecture arm64` **必须显式**跑，否则 §5 坑 C 重现（`opensslconf.h not found`）。
- Actions 上不需要 KVM，纯交叉编译即可。
- `mv ../` 语义：deb 落在 checkout 路径的**上一级**。用 `actions/checkout` 的 `path: kernel` 时，deb 在仓库根同级（即 `${GITHUB_WORKSPACE}/linux-image-*.deb` 而不是 `${GITHUB_WORKSPACE}/kernel/linux-image-*.deb`）。上面的 post-process 里 `../linux-image-*.deb` 正是这个位置。
- **cache key** 覆盖 `src/**` + `debian/patches/**` + `config-overrides/**` 三者变化。
- **可选叠加本地 patch**（`local-patches/*.patch`）：把自己的 config/驱动 fix 做成独立 patch，不侵入上游。

---

## 9. 一键本地脚本（等价 §4~§6，便于人工触发）

放在工作目录里叫 `build-a5e-kernel.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail
WORK="${1:-$PWD}"
cd "$WORK"

[ -d linux-aw2607-build ] || git clone --recursive --depth 1 --shallow-submodules \
    https://github.com/radxa-pkg/linux-aw2607.git linux-aw2607-build
cd linux-aw2607-build

# patch
for p in debian/patches/linux/000*.patch; do
    git apply -p1 "$p" 2>/dev/null || echo "already applied: $p"
done

# config
CFG=src/arch/arm64/configs/radxa.config
sed -i 's/^CONFIG_BRIDGE=m$/CONFIG_BRIDGE=y/'          "$CFG"
sed -i 's/^CONFIG_BRIDGE_NETFILTER=m$/CONFIG_BRIDGE_NETFILTER=y/' "$CFG"

# build
make build

# post
KVER="$(dpkg-parsechangelog -S Version)-aw2607"
mkdir -p ../out
dpkg-deb -x "../linux-image-${KVER}_*.deb" ../out/root
( cd ../out/root/lib/modules/$KVER
  find . -name '*.ko.xz' -print0 | while IFS= read -r -d '' f; do
      xz -dc "$f" > "${f%.xz}" && rm -f "$f"; done
  for m in modules.dep modules.alias modules.symbols modules.softdep \
           modules.devname modules.order modules.builtin.modinfo; do
      [ -f "$m" ] && sed -i 's/\.ko\.xz/.ko/g' "$m"; done
  rm -f *.bin )
cp src/arch/arm64/boot/Image ../out/vmlinuz

# 校验
grep -E '^kernel/net/bridge/bridge\.ko$|^kernel/net/802/stp\.ko$|^kernel/net/llc/llc\.ko$' \
     ../out/root/lib/modules/$KVER/modules.builtin
echo "OK → ../out/{vmlinuz,root/lib/modules/$KVER}"
```

用法：

```bash
./build-a5e-kernel.sh $WS
# 产物落在 ./out/vmlinuz 和 ./out/root/lib/modules/6.6.98-1-aw2607/
```

---

## 10. 与主记录 `../../OpenWrt-A5E-制作记录.md` 的关系

- **主记录 坑 7**：讲清"为什么 bridge 加载不了"—— 三层根因（`.ko.xz` / kmodloader 依赖解析失灵 / config_generate 表象）
- **本文 §5 坑 A~E**：讲清"重编内核时会再踩什么"
- 本文是**根治方案**；主记录坑 7 里的 init.d 预加载是**回退方案**（保留在 `owrt-a5e.img.bak-initd`）

## 11. 后续可优化 / 待办

- [ ] 把 `libssl-dev:arm64` 装不上时的错误消息更明确化（Actions 里常见）
- [ ] 提供**改任意 CONFIG_ 到 =y** 的通用 overlay patch 机制（而不是 sed）
- [ ] 增量编译 cache 命中率调优（目前 cache key 太宽，任一模块源码改动会全量失效）
- [ ] 加 WiFi 驱动（`aic8800`）的 module → builtin 试验；或干脆把整个 wireless 子系统也 builtin，避免 modprobe 依赖解析问题的连锁
- [ ] firewall 的 `nft_*` 模块也走同样套路（评估是模块坑 vs 服务配置坑）
