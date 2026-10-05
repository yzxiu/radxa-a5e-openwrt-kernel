#!/usr/bin/env bash
# 后处理：把内核 deb 变成"OpenWrt 可直用"的形态
#
# 步骤：
#   1. 从 deb 提取到 out/root/
#   2. 882 个 .ko.xz → .ko（OpenWrt kmodloader 无 xz 支持）
#   3. modules.dep/alias/symbols/... 里 .ko.xz 路径 sed 成 .ko
#   4. 删除 .bin 缓存（强制 kmodloader 读文本元数据）
#   5. 从未压缩源文件 src/arch/arm64/boot/Image 提取 vmlinuz
#      （deb 里的 /boot/vmlinuz 是 gzip，U-Boot extlinux 不认）
#
# 环境变量：
#   REPO_DIR, OUT_DIR, KERNEL_DIR （同 build.sh）

set -euo pipefail

REPO_DIR="${REPO_DIR:-$PWD}"
KERNEL_DIR="${KERNEL_DIR:-$REPO_DIR/kernel}"
OUT_DIR="${OUT_DIR:-$REPO_DIR/out}"

DEB=$(ls "$OUT_DIR"/linux-image-*_arm64.deb | head -1)
[ -n "$DEB" ] || { echo "找不到 linux-image-*.deb，先跑 build.sh"; exit 1; }

echo "=== [1/5] extract deb → $OUT_DIR/root/ ==="
rm -rf "$OUT_DIR/root"
mkdir -p "$OUT_DIR/root"
dpkg-deb -x "$DEB" "$OUT_DIR/root/"

# KVER 以解压出的 lib/modules 目录名为准。
# deb 文件名是 Debian 的 <pkg>_<upstreamver>_<arch>.deb 格式，
# 下划线把 version 段隔开了，纯靠文件名 sed 很容易漏剔（例如误得
# "6.6.98-1-aw2607_6.6.98-1"），而真实模块目录只到 KERNELRELEASE。
KVER=$(ls "$OUT_DIR/root/lib/modules/" 2>/dev/null | head -1)
[ -n "$KVER" ] || { echo "解压后找不到 lib/modules 子目录"; exit 1; }
echo "内核版本字符串 (取自 lib/modules): $KVER"

echo "=== [2/5] convert .ko.xz → .ko ==="
MODDIR="$OUT_DIR/root/lib/modules/$KVER"
[ -d "$MODDIR" ] || { echo "模块目录不存在: $MODDIR"; exit 1; }
(
  cd "$MODDIR"
  find . -name "*.ko.xz" -print0 | while IFS= read -r -d '' f; do
    xz -dc "$f" > "${f%.xz}" && rm -f "$f"
  done
  echo "  .ko 文件数: $(find . -name '*.ko' | wc -l)"
  echo "  .ko.xz 剩余: $(find . -name '*.ko.xz' | wc -l)"
)

echo "=== [3/5] 修 modules.dep / alias / symbols 里的 .ko.xz → .ko ==="
(
  cd "$MODDIR"
  for m in modules.dep modules.alias modules.symbols modules.softdep \
           modules.devname modules.order modules.builtin.modinfo; do
    [ -f "$m" ] && sed -i 's/\.ko\.xz/.ko/g' "$m" && echo "  ✓ $m"
  done
)

echo "=== [4/5] 删除 .bin 缓存（强制 kmodloader 走文本元数据）==="
(
  cd "$MODDIR"
  ls *.bin 2>/dev/null | sed 's/^/  /'
  rm -f *.bin
  echo "  剩余 .bin: $(ls *.bin 2>/dev/null | wc -l)"
)

echo "=== [5/5] 提取未压缩 vmlinuz（U-Boot 加载需要）==="
IMG="$KERNEL_DIR/src/arch/arm64/boot/Image"
[ -f "$IMG" ] || { echo "找不到 $IMG，内核没构建？"; exit 1; }
cp "$IMG" "$OUT_DIR/vmlinuz"
file "$OUT_DIR/vmlinuz"

# 汇总
echo
echo "=== 后处理完成 ==="
echo "产物："
echo "  deb:         $OUT_DIR/linux-image-*.deb"
echo "  vmlinuz:     $OUT_DIR/vmlinuz  ($(stat -c %s "$OUT_DIR/vmlinuz") 字节，未压缩)"
echo "  modules:     $OUT_DIR/root/lib/modules/$KVER/  ($(find "$OUT_DIR/root/lib/modules/$KVER" -type f | wc -l) 个文件)"
echo "  dtb:         $OUT_DIR/root/usr/lib/linux-image-$KVER/"

# 生成 sha256（方便下游烧录/校验）
( cd "$OUT_DIR" && sha256sum vmlinuz linux-image-*.deb > sha256sums.txt 2>/dev/null || true )
