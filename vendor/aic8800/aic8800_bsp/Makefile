CONFIG_SDIO_SUPPORT := y
CONFIG_SDIO_PWRCTRL := n
#CONFIG_AIC_FW_PATH = "/vendor/etc/firmware"

MODULE_NAME := aic8800_bsp
ifeq ($(CONFIG_SDIO_SUPPORT), y)
ccflags-y += -DAICWF_SDIO_SUPPORT
ccflags-$(CONFIG_SDIO_PWRCTRL) += -DCONFIG_SDIO_PWRCTRL
endif

CONFIG_GPIO_WAKEUP ?= n
CONFIG_M2D_OTA_AUTO_SUPPORT = n
CONFIG_M2D_OTA_LZMA_SUPPORT = n
CONFIG_LINK_DET_5G = y
CONFIG_MCU_MESSAGE = n
CONFIG_FIRMWARE_ARRAY = n
# Need to set fw path in BOARD_KERNEL_CMDLINE
CONFIG_USE_FW_REQUEST ?= n
CONFIG_FDRV_NO_REG_SDIO = n
CONFIG_VRF_DCDC_MODE = y
CONFIG_OOB ?= n
CONFIG_PREALLOC_TXQ = y
CONFIG_DPD = y
CONFIG_FORCE_DPD_CALIB = y
CONFIG_LOFT_CALIB = n
CONFIG_EXT_FEM_8800DCDW = n
CONFIG_RESV_MEM_SUPPORT ?= y
CONFIG_AMSDU_RX = y
CONFIG_IRQ_FALL ?= n
CONFIG_SDIO_BT = n
CONFIG_RADAR_OR_IR_DETECT =n
CONFIG_FOR_IPCAM = n
CONFIG_BAND_STEERING = n
CONFIG_PRBREQ_REPORT = n

ifeq ($(CONFIG_EXT_FEM_8800DCDW), y)
CONFIG_DPD = n
CONFIG_FORCE_DPD_CALIB = n
CONFIG_LOFT_CALIB = y
endif

ifeq ($(CONFIG_OOB), y)
CONFIG_GPIO_SET = y
endif

ccflags-$(CONFIG_GPIO_WAKEUP) += -DCONFIG_GPIO_WAKEUP
ccflags-$(CONFIG_M2D_OTA_AUTO_SUPPORT) += -DCONFIG_M2D_OTA_AUTO_SUPPORT
ccflags-$(CONFIG_M2D_OTA_LZMA_SUPPORT) += -DCONFIG_M2D_OTA_LZMA_SUPPORT
ccflags-$(CONFIG_LINK_DET_5G) += -DCONFIG_LINK_DET_5G
ccflags-$(CONFIG_MCU_MESSAGE) += -DCONFIG_MCU_MESSAGE
ccflags-$(CONFIG_FIRMWARE_ARRAY) += -DCONFIG_FIRMWARE_ARRAY
ccflags-$(CONFIG_USE_FW_REQUEST) += -DCONFIG_USE_FW_REQUEST
ccflags-$(CONFIG_FDRV_NO_REG_SDIO) += -DCONFIG_FDRV_NO_REG_SDIO
ccflags-$(CONFIG_VRF_DCDC_MODE) += -DCONFIG_VRF_DCDC_MODE
ccflags-$(CONFIG_OOB) += -DCONFIG_OOB
ccflags-$(CONFIG_PREALLOC_TXQ) += -DCONFIG_PREALLOC_TXQ
ccflags-$(CONFIG_DPD)  += -DCONFIG_DPD
ccflags-$(CONFIG_FORCE_DPD_CALIB) += -DCONFIG_FORCE_DPD_CALIB -DCONFIG_DPD
ccflags-$(CONFIG_LOFT_CALIB) += -DCONFIG_LOFT_CALIB
ccflags-$(CONFIG_EXT_FEM_8800DCDW) += -DCONFIG_EXT_FEM_8800DCDW
ccflags-$(CONFIG_RESV_MEM_SUPPORT) += -DCONFIG_RESV_MEM_SUPPORT
ccflags-$(CONFIG_AMSDU_RX) += -DCONFIG_AMSDU_RX
ccflags-$(CONFIG_IRQ_FALL) += -DCONFIG_IRQ_FALL
ccflags-$(CONFIG_SDIO_BT) += -DCONFIG_SDIO_BT
ccflags-$(CONFIG_RADAR_OR_IR_DETECT) += -DCONFIG_RADAR_OR_IR_DETECT
ccflags-$(CONFIG_FOR_IPCAM) += -DCONFIG_FOR_IPCAM
ccflags-$(CONFIG_BAND_STEERING) += -DCONFIG_BAND_STEERING
ccflags-$(CONFIG_PRBREQ_REPORT) += -DCONFIG_PRBREQ_REPORT
ccflags-$(CONFIG_GPIO_SET) += -DCONFIG_GPIO_SET

obj-$(CONFIG_AICV_WLAN_SUPPORT) := $(MODULE_NAME).o
$(MODULE_NAME)-y := \
	aic8800dc_compat.o \
	aic8800d80_compat.o \
	aic8800d80n_compat.o \
	aic8800d80x2_compat.o \
	aic_bsp_main.o \
	aic_bsp_driver.o \
	aicsdio.o \
	aicsdio_txrxif.o \
	md5.o

$(MODULE_NAME)-$(CONFIG_PREALLOC_TXQ)     += aicwf_txq_prealloc.o

ifeq ($(CONFIG_FIRMWARE_ARRAY),y)
$(MODULE_NAME)-y +=	aicwf_firmware_array.o
endif

########## Platform support list ##########
CONFIG_PLATFORM_ROCKCHIP ?= n
CONFIG_PLATFORM_ROCKCHIP2 ?= n
CONFIG_PLATFORM_ALLWINNER ?=n
CONFIG_PLATFORM_INGENIC_T20 ?= n
CONFIG_PLATFORM_AMLOGIC ?= n
CONFIG_PLATFORM_UBUNTU ?= y

ifeq ($(CONFIG_PLATFORM_ROCKCHIP), y)
ccflags-$(CONFIG_PLATFORM_ROCKCHIP) += -DCONFIG_PLATFORM_ROCKCHIP
KDIR ?= /home/yaya/E/Rockchip/3566/firefly/Android11.0/Firefly-RK356X_Android11.0_git_20210824/RK356X_Android11.0/kernel
ARCH ?= arm64
CROSS_COMPILE ?= /home/yaya/E/Rockchip/3566/Android11/rk3566_rk3568_android11_oranth/prebuilts/gcc/linux-x86/aarch64/gcc-linaro-6.3.1-2017.05-x86_64_aarch64-linux-gnu/bin/aarch64-linux-gnu-
endif

ifeq ($(CONFIG_PLATFORM_ROCKCHIP2), y)
ccflags-$(CONFIG_PLATFORM_ROCKCHIP2) += -DCONFIG_PLATFORM_ROCKCHIP2
ARCH ?= arm64
KDIR ?= /home/yaya/E/Rockchip/3566/firefly/Android11.0/Firefly-RK356X_Android11.0_git_20210824/RK356X_Android11.0/kernel
CROSS_COMPILE ?= /home/yaya/E/Rockchip/3566/firefly/Android11.0/Firefly-RK356X_Android11.0_git_20210824/RK356X_Android11.0/prebuilts/gcc/linux-x86/aarch64/gcc-linaro-6.3.1-2017.05-x86_64_aarch64-linux-gnu/bin/aarch64-linux-gnu-
endif

ifeq ($(CONFIG_PLATFORM_ALLWINNER), y)
ccflags-$(CONFIG_PLATFORM_ALLWINNER) += -DCONFIG_PLATFORM_ALLWINNER
KDIR  ?= /home/yaya/E/Allwinner/r818/Android10/lichee/kernel/linux-4.9/
ARCH ?= arm64
CROSS_COMPILE ?= /home/yaya/E/Allwinner/r818/Android10/android/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9/bin/aarch64-linux-android-

endif

ifeq ($(CONFIG_PLATFORM_INGENIC_T20), y)
KDIR ?= /home/yaya/E/T40/kernel
ARCH ?= mips
CROSS_COMPILE ?= /home/yaya/E/T40/mips-linux-gnu-ingenic-gcc7.2.0-glibc2.29-fp64/bin/mips-linux-gnu-
endif

ifeq ($(CONFIG_PLATFORM_AMLOGIC), y)
ccflags-$(CONFIG_PLATFORM_AMLOGIC) += -DCONFIG_PLATFORM_AMLOGIC
KDIR  ?= /home/aiden/D1/SDK/Amlogic/905x3_a9/android9.0/out/target/product/u202/obj/KERNEL_OBJ/
ARCH ?= arm
CROSS_COMPILE ?= /home/aiden/D1/SDK/Amlogic/905x3_a9/android9.0/prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.9/bin/arm-linux-androideabi-
endif

ifeq ($(CONFIG_PLATFORM_UBUNTU), y)
ccflags-$(CONFIG_PLATFORM_UBUNTU) += -DCONFIG_PLATFORM_UBUNTU
KDIR  ?= /lib/modules/$(shell uname -r)/build
PWD   ?= $(shell pwd)
KVER ?= $(shell uname -r)
MODDESTDIR ?= /lib/modules/$(KVER)/kernel/drivers/net/wireless/
ARCH ?= x86_64
CROSS_COMPILE ?=

ifeq ($(CONFIG_AW_BSP), y)
ccflags-y += -DCONFIG_PLATFORM_ALLWINNER
endif

endif
###########################################


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
