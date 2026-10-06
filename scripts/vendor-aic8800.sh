#!/usr/bin/env bash
# 从 AIC8800 DKMS 源树生成 vendor/aic8800/（内核树内建移植的清洗版）
#
# 来源：Debian 包 aic8800-sdio 5.0+git20260123.5f7be68d-8（板上验证过的版本）
#   /usr/src/aic8800-sdio-*/SDIO/driver_fw/driver/aic8800/
#
# 清洗内容（相对 DKMS 原始树）：
#   1. 顶层 Makefile：
#      - 删除 "Platform support list" 之后全部内容（KDIR/ARCH 外部编译 cruft +
#        all/modules/install/uninstall/clean 显式目标——与 kbuild 全局目标重名，
#        树内构建会覆盖 kbuild 的 modules 规则）
#      - 删除 CONFIG_AIC_* := m 三行（:= 会覆盖 auto.conf 里 Kconfig 的值，
#        fragment 的 =y 会被盖回 m）
#      - obj- 行显式重排为 bsp→fdrv→btlpm（builtin 时 initcall 按链接顺序执行，
#        bsp 必须先于 fdrv 初始化）
#   2. aic8800_bsp/Makefile：
#      - obj-m :=  → obj-$(CONFIG_AIC_WLAN_SUPPORT) :=（原写法强制模块，builtin 失效）
#      - 删除 CONFIG_AIC_FW_PATH 硬编码（改用 Kconfig 的 AIC_FW_PATH，由 fragment 配置）
#      - 删除尾部 all/modules/install/uninstall/clean 目标
#   3. aic8800_fdrv/Makefile：
#      - 删除 CONFIG_AIC8800_WLAN_SUPPORT = m（会覆盖 auto.conf 的 =y）
#      - 删除 ccflags 里的 CONFIG_AIC_FW_PATH 硬编码（改用 Kconfig 值）
#      - 删除尾部显式目标
#   4. aic8800_btlpm/Makefile：
#      - 删除 CONFIG_AIC8800_BTLPM_SUPPORT = m
#      - 删除尾部显式目标
#
# 用法：SRC=<dkms源树路径> ./scripts/vendor-aic8800.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${SRC:?用法: SRC=<dkms源树> $0}"
SRC="$SRC/SDIO/driver_fw/driver/aic8800"
DST="$REPO_DIR/vendor/aic8800"

rm -rf "$DST"
mkdir -p "$DST"
cp -a "$SRC"/. "$DST"/
# 顶层 Kconfig 的 source 路径（drivers/net/wireless/aic8800/...）与植入位置一致，原样保留

# ---- 顶层 Makefile ----
TOP="$DST/Makefile"
sed -i '/^########## Platform support list/,$d' "$TOP"
sed -i '/^CONFIG_AIC8800_BTLPM_SUPPORT := m/d; /^CONFIG_AIC8800_WLAN_SUPPORT := m/d; /^CONFIG_AIC_WLAN_SUPPORT := m/d' "$TOP"
grep -v '^obj-\$' "$TOP" > "$TOP.tmp"
{
  echo 'obj-$(CONFIG_AIC_WLAN_SUPPORT) += aic8800_bsp/       # bsp 最先：builtin 时 initcall 按链接顺序执行'
  echo 'obj-$(CONFIG_AIC8800_WLAN_SUPPORT) += aic8800_fdrv/'
  echo 'obj-$(CONFIG_AIC8800_BTLPM_SUPPORT) += aic8800_btlpm/'
  cat "$TOP.tmp"
} > "$TOP"
rm -f "$TOP.tmp"

# ---- bsp ----
BSP="$DST/aic8800_bsp/Makefile"
sed -i 's|^obj-m := \$(MODULE_NAME).o|obj-$(CONFIG_AIC_WLAN_SUPPORT) := $(MODULE_NAME).o|' "$BSP"
sed -i '/^CONFIG_AIC_FW_PATH = /d; /^export CONFIG_AIC_FW_PATH/d; /^ccflags-y += -DCONFIG_AIC_FW_PATH/d' "$BSP"
sed -i '/^all: modules/,$d' "$BSP"

# ---- fdrv ----
FDRV="$DST/aic8800_fdrv/Makefile"
sed -i '/^CONFIG_AIC8800_WLAN_SUPPORT = m/d' "$FDRV"
sed -i '/^ccflags-y += -DCONFIG_AIC_FW_PATH/d' "$FDRV"
sed -i '/^all: modules/,$d' "$FDRV"

# ---- btlpm ----
BTLPM="$DST/aic8800_btlpm/Makefile"
sed -i '/^CONFIG_AIC8800_BTLPM_SUPPORT = m/d' "$BTLPM"
sed -i '/^all: modules/,$d' "$BTLPM"

find "$DST" \( -name '*.o' -o -name '*.cmd' -o -name '*.mod*' -o -name '.tmp*' \) -delete

# ---- 符号隔离：bsp 子模块自带同源码的 AIC8800（radxa.config 里 CONFIG_AIC_WLAN_SUPPORT=n
# 禁用）。我们的移植版若沿用原符号名，merge 时会和 bsp 的开关互相干扰；源码不引用这些
# 宏（已全量 grep 验证；CONFIG_AIC_FW_PATH 例外：源码直接引用该宏且 bsp 树无此符号，
# 保留原名让 autoconf 直接生成，值由 fragment 的 CONFIG_AIC_FW_PATH 提供）。
find "$DST" \( -name 'Kconfig*' -o -name 'Makefile' \) -exec sed -i \
  -e 's/CONFIG_AIC8800_BTLPM_SUPPORT/CONFIG_AICV8800_BTLPM_SUPPORT/g' \
  -e 's/CONFIG_AIC8800_WLAN_SUPPORT/CONFIG_AICV8800_WLAN_SUPPORT/g' \
  -e 's/CONFIG_AIC_WLAN_SUPPORT/CONFIG_AICV_WLAN_SUPPORT/g' \
  {} +
# Kconfig 文件用裸符号名（不带 CONFIG_ 前缀），单独一轮替换；AIC_FW_PATH 保留原名
# （源码直接引用 CONFIG_AIC_FW_PATH 宏，且 bsp 树无此符号，无冲突）
find "$DST" -name 'Kconfig*' -exec sed -i \
  -e 's/\bAIC8800_BTLPM_SUPPORT\b/AICV8800_BTLPM_SUPPORT/g' \
  -e 's/\bAIC8800_WLAN_SUPPORT\b/AICV8800_WLAN_SUPPORT/g' \
  -e 's/\bAIC_WLAN_SUPPORT\b/AICV_WLAN_SUPPORT/g' \
  {} +

# ---- 初始化时机：device_initcall → late_initcall ----
# builtin 时 aic 的 module_init 在 0.34s 就执行，早于 PMIC(axp2202) 稳压器、
# sunxi-rfkill（~3.1s）、mmc2/sdio 枚举等基础设施，aicbsp_platform_power_on 必失败
# （板上实测：fail to set AIC_WIFI power state to 1）。模块方案没这问题纯粹因为
# insmod 时基础设施早已就绪。改成 late_initcall 等它们全部就位。
# 注意：本移植只用于 builtin，此改动对模块构建不适用（也不需要）。
sed -i 's/^module_init(aicbsp_init);/late_initcall(aicbsp_init);/' "$DST/aic8800_bsp/aic_bsp_main.c"
sed -i 's/^module_init(rwnx_mod_init);/late_initcall(rwnx_mod_init);/' "$DST/aic8800_fdrv/rwnx_main.c"

# ---- bsp 侧同名内部符号去重（builtin 必需）----
# DKMS 双模块架构里 bsp/fdrv 各自带一份私有同名副本（md5、SDIO 传输层、cmd 助手、
# 全局变量），做成模块互不冲突，但 builtin 进同一 vmlinux 会 multiple definition。
# 已用 nm 全量核实：这些符号的未定义引用全部是模块内自包含（fdrv 不引用 bsp 副本，
# 反之亦然），因此对 bsp 侧做源码级 -D 改名（定义与引用一致改写）不改变运行时语义。
# 列表生成方法：对比两目录 .o 的 nm T/D/B/R 全局符号交集（aic8800-sdio 5.0+git20260123）。
cat >> "$DST/aic8800_bsp/Makefile" <<'MAKEEOF'

# ==== aicv: rename symbols colliding with aic8800_fdrv (builtin dedup) ====
ccflags-y += -DMD5Decode=aicv_bsp_MD5Decode -DMD5Encode=aicv_bsp_MD5Encode
ccflags-y += -DMD5Final=aicv_bsp_MD5Final -DMD5Init=aicv_bsp_MD5Init
ccflags-y += -DMD5Transform=aicv_bsp_MD5Transform -DMD5Update=aicv_bsp_MD5Update
ccflags-y += -DPADDING=aicv_bsp_PADDING -Daic_fw_path=aicv_bsp_aic_fw_path
ccflags-y += -Daicwf_bus_deinit=aicv_bsp_aicwf_bus_deinit -Daicwf_bus_init=aicv_bsp_aicwf_bus_init
ccflags-y += -Daicwf_dev_skb_free=aicv_bsp_aicwf_dev_skb_free
ccflags-y += -Daicwf_frame_dequeue=aicv_bsp_aicwf_frame_dequeue -Daicwf_frame_enq=aicv_bsp_aicwf_frame_enq
ccflags-y += -Daicwf_frame_queue_flush=aicv_bsp_aicwf_frame_queue_flush
ccflags-y += -Daicwf_frame_queue_init=aicv_bsp_aicwf_frame_queue_init
ccflags-y += -Daicwf_frame_queue_peek_tail=aicv_bsp_aicwf_frame_queue_peek_tail
ccflags-y += -Daicwf_frame_tx=aicv_bsp_aicwf_frame_tx
ccflags-y += -Daicwf_is_framequeue_empty=aicv_bsp_aicwf_is_framequeue_empty
ccflags-y += -Daicwf_process_rxframes=aicv_bsp_aicwf_process_rxframes
ccflags-y += -Daicwf_rx_deinit=aicv_bsp_aicwf_rx_deinit -Daicwf_rx_init=aicv_bsp_aicwf_rx_init
ccflags-y += -Daicwf_rxframe_enqueue=aicv_bsp_aicwf_rxframe_enqueue
ccflags-y += -Daicwf_sdio_aggr=aicv_bsp_aicwf_sdio_aggr
ccflags-y += -Daicwf_sdio_aggr_send=aicv_bsp_aicwf_sdio_aggr_send
ccflags-y += -Daicwf_sdio_aggrbuf_reset=aicv_bsp_aicwf_sdio_aggrbuf_reset
ccflags-y += -Daicwf_sdio_bus_init=aicv_bsp_aicwf_sdio_bus_init
ccflags-y += -Daicwf_sdio_flow_ctrl=aicv_bsp_aicwf_sdio_flow_ctrl
ccflags-y += -Daicwf_sdio_func_deinit=aicv_bsp_aicwf_sdio_func_deinit
ccflags-y += -Daicwf_sdio_func_init=aicv_bsp_aicwf_sdio_func_init
ccflags-y += -Daicwf_sdio_hal_irqhandler=aicv_bsp_aicwf_sdio_hal_irqhandler
ccflags-y += -Daicwf_sdio_readb=aicv_bsp_aicwf_sdio_readb
ccflags-y += -Daicwf_sdio_readframes=aicv_bsp_aicwf_sdio_readframes
ccflags-y += -Daicwf_sdio_recv_pkt=aicv_bsp_aicwf_sdio_recv_pkt
ccflags-y += -Daicwf_sdio_reg_init=aicv_bsp_aicwf_sdio_reg_init
ccflags-y += -Daicwf_sdio_release=aicv_bsp_aicwf_sdio_release
ccflags-y += -Daicwf_sdio_send=aicv_bsp_aicwf_sdio_send
ccflags-y += -Daicwf_sdio_send_pkt=aicv_bsp_aicwf_sdio_send_pkt
ccflags-y += -Daicwf_sdio_txpkt=aicv_bsp_aicwf_sdio_txpkt
ccflags-y += -Daicwf_sdio_writeb=aicv_bsp_aicwf_sdio_writeb
ccflags-y += -Daicwf_sdiov3_func_init=aicv_bsp_aicwf_sdiov3_func_init
ccflags-y += -Daicwf_tx_deinit=aicv_bsp_aicwf_tx_deinit -Daicwf_tx_init=aicv_bsp_aicwf_tx_init
ccflags-y += -Dchip_mcu_id=aicv_bsp_chip_mcu_id -Dchip_sub_id=aicv_bsp_chip_sub_id
ccflags-y += -Dcrc8_ponl_107=aicv_bsp_crc8_ponl_107
ccflags-y += -Drwnx_cmd_mgr_deinit=aicv_bsp_rwnx_cmd_mgr_deinit
ccflags-y += -Drwnx_cmd_mgr_init=aicv_bsp_rwnx_cmd_mgr_init
ccflags-y += -Drwnx_rx_handle_msg=aicv_bsp_rwnx_rx_handle_msg
ccflags-y += -Drwnx_send_dbg_mem_block_write_req=aicv_bsp_rwnx_send_dbg_mem_block_write_req
ccflags-y += -Drwnx_send_dbg_mem_mask_write_req=aicv_bsp_rwnx_send_dbg_mem_mask_write_req
ccflags-y += -Drwnx_send_dbg_mem_read_req=aicv_bsp_rwnx_send_dbg_mem_read_req
ccflags-y += -Drwnx_send_dbg_mem_write_req=aicv_bsp_rwnx_send_dbg_mem_write_req
ccflags-y += -Drwnx_send_dbg_start_app_req=aicv_bsp_rwnx_send_dbg_start_app_req
ccflags-y += -Dtestmode=aicv_bsp_testmode
MAKEEOF
echo "vendor/aic8800/ 生成完成: $(find "$DST" -type f | wc -l) files, $(du -sh "$DST" | cut -f1)"
