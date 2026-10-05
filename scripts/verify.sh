#!/usr/bin/env bash
# 校验：确认 fragment 要求的所有 CONFIG 都真的编进了内核（=y 内建）
#
# 核心判据 = deb 里的 boot/config-<KVER>，对每个 CONFIG 直接确认 "=y"。
#   · 这样 bool 和 tristate 通吃（modules.builtin 只记 tristate 内建，会漏报 bool，
#     例如 CONFIG_NF_SOCKET_IPV4 是 bool，内建进 vmlinux 但不在 modules.builtin）
#   · 目标列表从 configs/a5e-openwrt.config 动态读取，fragment 改了这里自动跟随
# 另用 modules.builtin 抽查关键 tristate 模块，证明 .ko 真的并进 vmlinux（不是只写了 config）。
#
# 环境变量：REPO_DIR, OUT_DIR, KERNEL_DIR

set -uo pipefail

REPO_DIR="${REPO_DIR:-$PWD}"
OUT_DIR="${OUT_DIR:-$REPO_DIR/out}"
ROOT="$OUT_DIR/root"
fail=0

# 定位 KVER（以解压出的 lib/modules 目录名为准）
if [ ! -d "$ROOT/lib/modules" ]; then
  echo "找不到 $ROOT/lib/modules，先跑 build.sh + post-process.sh"; exit 1
fi
KVER=$(ls "$ROOT/lib/modules/" | head -1)
MODDIR="$ROOT/lib/modules/$KVER"
BUILTIN="$MODDIR/modules.builtin"
CONFIG="$ROOT/boot/config-$KVER"
FRAGMENT="$REPO_DIR/configs/a5e-openwrt.config"

echo "=== 内核版本: $KVER ==="
echo

# ---------- 1. 主判据：fragment 每条 CONFIG 在最终 config 里都 =y ----------
if [ ! -f "$CONFIG" ]; then
  echo "✗ 找不到内核 config：$CONFIG"
  echo "  （deb 未含 /boot/config-* 时，回退用 KERNEL_DIR/src/.config 校验）"
  CONFIG="$REPO_DIR/kernel/src/.config"
  [ -f "$CONFIG" ] || { echo "✗ 回退 config 也不存在，无法校验"; exit 1; }
fi

if [ ! -f "$FRAGMENT" ]; then
  echo "✗ 找不到 fragment：$FRAGMENT（无法核对目标 CONFIG）"; exit 1
fi

echo "=== 1. fragment 要求的 CONFIG 是否全部 =y（内建进 vmlinux）==="
total=0; bad=0
for c in $(grep '^CONFIG_' "$FRAGMENT" | sed 's/=.*//'); do
  total=$((total+1))
  line=$(grep -E "^${c}=" "$CONFIG" | head -1)
  if [ "$line" = "${c}=y" ]; then
    :   # ✓ 静默（项多，全绿时只报汇总）
  else
    echo "  ✗ ${c}  →  ${line:-（config 里没有该行）}"
    bad=$((bad+1))
  fi
done
# 额外核对 Kconfig select 自动带出的（不写在 fragment 里，但必须 =y）
for c in CONFIG_LLC CONFIG_STP; do
  total=$((total+1))
  line=$(grep -E "^${c}=" "$CONFIG" | head -1)
  [ "$line" = "${c}=y" ] || { echo "  ✗ ${c}（BRIDGE select 带出）→ ${line:-缺}"; bad=$((bad+1)); }
done
if [ "$bad" = "0" ]; then
  echo "  ✓ 全部 $total 项目标 CONFIG 都 =y（bridge 自动带出 LLC/STP 也在）"
else
  echo "  ✗ $bad/$total 未内建"
fi
fail=$((fail+bad))
echo

# ---------- 2. 交叉验证：关键 tristate 模块已从 modules 目录消失（真进 vmlinux）----------
echo "=== 2. 关键 tristate .ko 应已从模块目录消失（并进 vmlinux）==="
for m in bridge br_netfilter nf_tables nf_conntrack nf_nat nft_ct nft_tproxy nft_fib; do
  # bool 类不在 builtin，只查 tristate；modules.builtin 有该 basename 且 modules 目录无同名 .ko 才算通过
  found_builtin=$(grep -E "/${m}\.ko$" "$BUILTIN" 2>/dev/null | head -1)
  leftover=$(find "$MODDIR" -name "${m}.ko" 2>/dev/null | head -1)
  if [ -n "$found_builtin" ] && [ -z "$leftover" ]; then
    echo "  ✓ ${m}.ko → $found_builtin（已内建，无残留）"
  elif [ -n "$leftover" ]; then
    echo "  ✗ ${m}.ko 仍在模块目录（未内建？）: $leftover"; fail=$((fail+1))
  else
    echo "  ? ${m}.ko 不在 modules.builtin（若是 bool 则正常；tristate 则异常）"
  fi
done
echo

# ---------- 3. 无 .ko.xz 残留 ----------
echo "=== 3. .ko.xz 是否已全部展开 ==="
xz_count=$(find "$MODDIR" -name "*.ko.xz" 2>/dev/null | wc -l)
[ "$xz_count" = "0" ] && echo "  ✓ 0 个 .ko.xz" || { echo "  ✗ 还有 $xz_count 个 .ko.xz"; fail=$((fail+1)); }
ko_count=$(find "$MODDIR" -name "*.ko" 2>/dev/null | wc -l)
echo "  .ko 文件数: $ko_count"
echo

# ---------- 4. modules.dep 依赖闭环 ----------
echo "=== 4. modules.dep 里的依赖项是否都真实存在 ==="
missing=0
while IFS= read -r line; do
  case "$line" in
    *": "*)
      for d in ${line#*: }; do
        [ -e "$MODDIR/$d" ] || { echo "  MISS: $d  (from ${line%%:*})"; missing=$((missing+1)); }
      done ;;
  esac
done < "$MODDIR/modules.dep"
[ "$missing" = "0" ] && echo "  ✓ 无缺失依赖" || { echo "  ✗ $missing 条悬空依赖"; fail=$((fail+1)); }
echo

# ---------- 5. vmlinuz 未压缩 ----------
echo "=== 5. vmlinuz 是否为未压缩 ARM64 Image ==="
if [ -f "$OUT_DIR/vmlinuz" ] && file "$OUT_DIR/vmlinuz" | grep -q "Linux kernel ARM64 boot executable Image"; then
  echo "  ✓ 未压缩 ARM64 Image ($(stat -c %s "$OUT_DIR/vmlinuz") 字节)"
else
  echo "  ✗ vmlinuz 不存在或不是未压缩 Image"; fail=$((fail+1))
fi
echo

# ---------- 6. a5e dtb ----------
echo "=== 6. a5e dtb 是否就位 ==="
dtb="$ROOT/usr/lib/linux-image-$KVER/allwinner/sun55i-a527-cubie-a5e.dtb"
[ -f "$dtb" ] && echo "  ✓ $dtb" || { echo "  ✗ 缺 a5e dtb"; fail=$((fail+1)); }
echo

if [ "$fail" -eq 0 ]; then
  echo "===== ✅ 所有校验通过 ====="
  exit 0
else
  echo "===== ❌ 校验失败：$fail 项 ====="
  exit 1
fi
