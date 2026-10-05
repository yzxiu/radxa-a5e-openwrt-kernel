#!/usr/bin/env bash
# A5E OpenWrt 定制内核一键构建（本地/CI 共用）
#
# 步骤：clone linux-aw2607 → apply debian patches → 装我们的 fragment → make build
#
# 环境变量（可覆盖）：
#   REPO_DIR    本仓库根（默认 $PWD）
#   KERNEL_DIR  内核源码工作目录（默认 $REPO_DIR/kernel）
#   OUT_DIR     产物目录（默认 $REPO_DIR/out）
#   KERNEL_URL  上游仓库 URL（默认 https://github.com/yzxiu/linux-aw2607.git，即 radxa-pkg 的 fork）
#   KERNEL_REF  上游 ref（默认 main；填具体 sha/branch/tag）
#   SHALLOW     是否浅 clone（默认 1；设 0 完整 clone 便于非 main 分支 checkout）

set -euo pipefail

REPO_DIR="${REPO_DIR:-$PWD}"
KERNEL_DIR="${KERNEL_DIR:-$REPO_DIR/kernel}"
OUT_DIR="${OUT_DIR:-$REPO_DIR/out}"
KERNEL_URL="${KERNEL_URL:-https://github.com/yzxiu/linux-aw2607.git}"
KERNEL_REF="${KERNEL_REF:-main}"
SHALLOW="${SHALLOW:-1}"

# GitHub Actions 里 safe.directory 需要显式；本地也一并加，无害
git config --global --add safe.directory "$KERNEL_DIR" 2>/dev/null || true
git config --global --add safe.directory "$KERNEL_DIR/src" 2>/dev/null || true
git config --global --add safe.directory "$KERNEL_DIR/bsp" 2>/dev/null || true
git config --global --add safe.directory "$KERNEL_DIR/device-a527" 2>/dev/null || true

# ---------- 1. clone ----------
if [ ! -d "$KERNEL_DIR/src" ]; then
  echo "=== [1/4] clone linux-aw2607 ($KERNEL_URL @ $KERNEL_REF) ==="
  if [ "$SHALLOW" = "1" ] && [ "$KERNEL_REF" = "main" ]; then
    git clone --recursive --depth 1 --shallow-submodules "$KERNEL_URL" "$KERNEL_DIR"
  else
    git clone --recursive "$KERNEL_URL" "$KERNEL_DIR"
    ( cd "$KERNEL_DIR" && git checkout "$KERNEL_REF" && git submodule update --init --recursive )
  fi
else
  echo "=== [1/4] 已存在 $KERNEL_DIR，跳过 clone ==="
fi

cd "$KERNEL_DIR"

# ---------- 1.5 patch Makefile.extra：避免 host 工具变 aarch64 执行不了 ----------
# Radxa 硬编码 HOSTCC=$(CROSS_COMPILE)gcc → fixdep/extract-cert/dtc 等 host 工具
# 会被编成 aarch64 二进制。本地 rsdk devcontainer 有 qemu-user-static +
# binfmt_misc 能透明执行；GitHub Actions container job 没有 --privileged，
# container 内看不到 binfmt_misc → 内核 scripts_basic 步骤 Exec format error。
# 改成 HOSTCC=gcc，host 工具用 host gcc（x86_64）编；target 仍走交叉编译器。
# 本地/Actions 都能跑。
echo "=== [1.5] patch Makefile.extra: HOSTCC aarch64 → host gcc ==="
if grep -q 'HOSTCC=\$(CROSS_COMPILE)gcc' Makefile.extra 2>/dev/null; then
  sed -i 's|HOSTCC=\$(CROSS_COMPILE)gcc|HOSTCC=gcc|' Makefile.extra
  echo "  patched: HOSTCC=aarch64-linux-gnu-gcc → HOSTCC=gcc"
else
  echo "  已 patch 过或 pattern 不存在，skip"
fi

# ---------- 2. apply debian patches ----------
echo "=== [2/4] apply debian patches (all -p1 from repo top) ==="
for p in debian/patches/linux/000*.patch; do
  if [ ! -f "$p" ]; then continue; fi
  if git apply -p1 --check "$p" 2>/dev/null; then
    git apply -p1 "$p"
    echo "  applied: $(basename "$p")"
  else
    echo "  skip (already applied or conflict): $(basename "$p")"
  fi
done

# 允许仓库带自己的额外 patch（可选）
if [ -d "$REPO_DIR/patches" ]; then
  for p in "$REPO_DIR"/patches/*.patch; do
    [ -f "$p" ] || continue
    if git apply -p1 --check "$p" 2>/dev/null; then
      git apply -p1 "$p"
      echo "  applied (local): $(basename "$p")"
    fi
  done
fi

# ---------- 3. 安装我们的 fragment ----------
echo "=== [3/4] install kernel fragment ==="
FRAGMENT_SRC="$REPO_DIR/configs/a5e-openwrt.config"
[ -f "$FRAGMENT_SRC" ] || { echo "缺少 $FRAGMENT_SRC"; exit 1; }

# 同时保留一份到 configs/ 方便追溯（不会重复注入）
cp "$FRAGMENT_SRC" src/arch/arm64/configs/a5e-openwrt.config

# 采用“追加到 radxa.config 末尾”的方式而非传第三个 fragment：
#   - Radxa 上游的 KERNEL_DEFCONFIG="defconfig radxa.config" 已验证可跑通
#   - Kbuild merge_config 语义：同 CONFIG 后出现的会覆盖先出现的
#   - 避开多 fragment 命令行在某些内核 Kconfig 依赖下报“beyond Kconfig”的坑
# 幂等：Actions 上 cache 恢复后重跑时，已 cat 过的不重复 cat
if grep -q "^# ==== appended by radxa-a5e-openwrt-kernel" src/arch/arm64/configs/radxa.config 2>/dev/null; then
  echo "  fragment 已 append 过，skip"
else
  {
    echo ""
    echo "# ==== appended by radxa-a5e-openwrt-kernel (a5e-openwrt.config) ===="
    echo "# 目的：让 bridge / fw4 / tproxy 进 vmlinux，避开 OpenWrt kmodloader 依赖解析失灵"
    grep "^CONFIG_" "$FRAGMENT_SRC"
  } >> src/arch/arm64/configs/radxa.config
  echo "  appended $(grep -cE '^CONFIG_' "$FRAGMENT_SRC") CONFIG lines to src/arch/arm64/configs/radxa.config"
fi

# ---------- 4. build ----------
echo "=== [4/4] make build ==="
mkdir -p "$OUT_DIR"
# 上面已经把 fragment 内容 cat 到 radxa.config 里了，这里用上游默认命令即可
make build

# Makefile.extra 里 `mv linux-*_arm64.deb ../` 会把 deb 落到 KERNEL_DIR/../ 里，
# 也就是 OUT_DIR 的兄弟位置。统一收集到 OUT_DIR。
mv ../linux-image-*_arm64.deb "$OUT_DIR/" 2>/dev/null || true
mv ../linux-headers-*_arm64.deb "$OUT_DIR/" 2>/dev/null || true
mv ../linux-libc-dev_*_arm64.deb "$OUT_DIR/" 2>/dev/null || true
mv ../linux-upstream*_arm64.changes "$OUT_DIR/" 2>/dev/null || true
mv ../linux-upstream*_arm64.buildinfo "$OUT_DIR/" 2>/dev/null || true

echo
echo "=== build 完成，产物： ==="
ls -lh "$OUT_DIR"/*.deb 2>/dev/null
