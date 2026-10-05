#!/usr/bin/env bash
# 校验：确认 fragment 的目标 CONFIG 都真的进了 vmlinux
#
# 检查项：
#   1. modules.builtin 里包含 bridge/stp/llc + fw4 核心 + tproxy 组
#   2. .ko.xz 已全部转成 .ko
#   3. vmlinuz 是未压缩 ARM64 Image
#   4. modules.dep 里没有对已 builtin 模块的悬空依赖
#
# 环境变量：OUT_DIR, KERNEL_DIR

set -uo pipefail

REPO_DIR="${REPO_DIR:-$PWD}"
OUT_DIR="${OUT_DIR:-$REPO_DIR/out}"
ROOT="$OUT_DIR/root"
fail=0

if [ ! -d "$ROOT/lib/modules" ]; then
  echo "找不到 $ROOT/lib/modules，先跑 build.sh + post-process.sh"
  exit 1
fi
KVER=$(ls "$ROOT/lib/modules/" | head -1)
BUILTIN="$ROOT/lib/modules/$KVER/modules.builtin"
MODDIR="$ROOT/lib/modules/$KVER"

echo "=== 1. modules.builtin 里的关键模块（bridge/fw4/tproxy）==="
expected=(
  # bridge
  "kernel/net/bridge/bridge.ko"
  "kernel/net/802/stp.ko"
  "kernel/net/llc/llc.ko"
  "kernel/net/bridge/br_netfilter.ko"
  # fw4 core
  "kernel/net/netfilter/nf_tables.ko"
  "kernel/net/netfilter/nf_conntrack.ko"
  "kernel/net/netfilter/nf_nat.ko"
  # nft expressions
  "kernel/net/netfilter/nft_ct.ko"
  "kernel/net/netfilter/nft_masq.ko"
  "kernel/net/netfilter/nft_redir.ko"
  "kernel/net/netfilter/nft_reject.ko"
  "kernel/net/netfilter/nft_compat.ko"
  # tproxy / socket / dup
  "kernel/net/netfilter/nft_tproxy.ko"
  "kernel/net/netfilter/nf_socket_ipv4.ko"
  "kernel/net/netfilter/nf_socket_ipv6.ko"
  "kernel/net/ipv4/netfilter/nf_tproxy_ipv4.ko"
  "kernel/net/ipv6/netfilter/nf_tproxy_ipv6.ko"
)
for t in "${expected[@]}"; do
  if grep -qxF "$t" "$BUILTIN"; then
    printf "  ✓ %s\n" "$t"
  else
    printf "  ✗ %s\n" "$t"
    fail=$((fail+1))
  fi
done

echo
echo "=== 2. 这些 .ko 文件应当已从 modules 目录消失（已进 vmlinux）==="
for t in "${expected[@]}"; do
  if [ -e "$MODDIR/$t" ]; then
    printf "  ✗ 意外残留: %s\n" "$t"
    fail=$((fail+1))
  fi
done
echo "  完成（有 ✗ 说明该 CONFIG 并未真正 builtin）"

echo
echo "=== 3. 无 .ko.xz 残留 ==="
xz_count=$(find "$MODDIR" -name "*.ko.xz" 2>/dev/null | wc -l)
if [ "$xz_count" = "0" ]; then
  echo "  ✓ 0 个 .ko.xz"
else
  echo "  ✗ 还有 $xz_count 个 .ko.xz 未转"
  fail=$((fail+1))
fi

echo
echo "=== 4. modules.dep 里的所有依赖项都真实存在（避免 modprobe ENOENT）==="
missing=0
while IFS= read -r line; do
  case "$line" in
    *": "*)
      deps="${line#*: }"
      for d in $deps; do
        [ -e "$MODDIR/$d" ] || { echo "  MISS: $d  (from: ${line%%:*})"; missing=$((missing+1)); }
      done
      ;;
  esac
done < "$MODDIR/modules.dep"
if [ "$missing" = "0" ]; then
  echo "  ✓ 无缺失依赖"
else
  echo "  ✗ 有 $missing 条悬空依赖"
  fail=$((fail+1))
fi

echo
echo "=== 5. vmlinuz 是未压缩 ARM64 Image ==="
if [ -f "$OUT_DIR/vmlinuz" ] && file "$OUT_DIR/vmlinuz" | grep -q "Linux kernel ARM64 boot executable Image"; then
  echo "  ✓ 未压缩 ARM64 Image ($(stat -c %s "$OUT_DIR/vmlinuz") 字节)"
else
  echo "  ✗ vmlinuz 不存在或格式不对"
  fail=$((fail+1))
fi

echo
echo "=== 6. a5e dtb 就位 ==="
dtb="$OUT_DIR/root/usr/lib/linux-image-$KVER/allwinner/sun55i-a527-cubie-a5e.dtb"
if [ -f "$dtb" ]; then
  echo "  ✓ $dtb"
else
  echo "  ✗ 缺 a5e dtb"
  fail=$((fail+1))
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "===== 所有验证通过 ====="
  exit 0
else
  echo "===== 验证失败：$fail 项 ====="
  exit 1
fi
