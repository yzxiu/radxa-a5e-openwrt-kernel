# OpenWrt 镜像 — 定制内核替换（可复用流程）

> 每次 `radxa-a5e-openwrt-kernel` 编译流水线产出新内核（`out/` 或本地 `dpkg-deb -x` 结果）后，
> 用本文流程把镜像 `owrt-a5e.img` 里的旧内核**原地替换**成新内核，全程**免 root**、可重复执行。
> 这是"方案 C 拼装"定稿后的**日常更新动作**——只换内核，不动 rootfs 里其它已固化的配置
> （network / firewall / dropbear / extlinux append / 80_mount_root 短路等全部保留）。

配套文档：
- 编译产物怎么来 → `../README.md`、`A5E-内核编译-记录.md`（同目录 docs/）
- 为什么必须 builtin bridge → `../../OpenWrt-A5E-制作记录.md` 坑 7

---

## 0. 输入产物长什么样（三选一）

替换只需要三样东西，路径名固定：

| 需要的东西 | 来源 | 关键属性 |
|---|---|---|
| **未压缩 vmlinuz** | `kernel/src/arch/arm64/boot/Image`（Actions artifact 里叫 `vmlinuz`） | 必须是 `Linux kernel ARM64 boot executable Image`，**不能**用 deb 里那个 gzip 的 `boot/vmlinuz-*`（U-Boot extlinux 不认，见坑记录 §5-A） |
| **处理好的 /lib/modules/** | `out/root/lib/modules/<KVER>/` | `.ko.xz` 已展开成 `.ko`、`modules.dep` 路径已修、`.bin` 已删 |
| **dtb** | `out/root/usr/lib/linux-image-<KVER>/allwinner/*.dtb` | 至少要有 `sun55i-a527-cubie-a5e.dtb` |

**拿产物的三种方式**：

```bash
# 方式 A：跑 Actions，下载 artifact（推荐，产出即上面 out/ 结构）
#   仓库页 Actions → Build A5E OpenWrt Kernel → 最新成功 run → Artifacts 里
#   a5e-kernel-<run>  → 解压得到 out/{vmlinuz,root/lib/modules,root/usr/lib/linux-image-*}

# 方式 B：本地跑编译仓库脚本（产出同样 out/ 结构）
cd radxa-a5e-openwrt-kernel
./scripts/build.sh && ./scripts/post-process.sh && ./scripts/verify.sh
# → radxa-a5e-openwrt-kernel/out/

# 方式 C：手上只有裸 deb（比如 rsdk 直接产出的），手动后处理
dpkg-deb -x linux-image-6.6.98-1-aw2607_*.deb work/
# 然后按 §2 把 work/lib/modules/<KVER> 里的 .ko.xz 转 .ko
```

本文档假设产物已就位为 `out/`（方式 A/B）。KVER 从 deb 名或 `out/root/lib/modules/` 目录名读出。

---

本文所有路径基于**工作根** `$WS`（你检出 `radxa-a5e` 的位置），先设一次：

```bash
export WS="$HOME/work/radxa-a5e"   # ← 换成你自己的实际路径
```

## 1. 固定常量（A5E 镜像专用）

```bash
IMG=$WS/owrt-a5e.img
KVER=6.6.98-1-aw2607          # 换内核若改了版本字符串，这里同步，且见 §5 的 extlinux 提醒
OUT=$WS/radxa-a5e-openwrt-kernel/out   # 新内核产物目录

# GPT 第 3 分区（rootfs, ext4）—— 已实测锁定
LBA_START=679936              # rootfs 分区起始扇区
LBA_COUNT=998433             # rootfs 分区扇区数（×512 ≈ 487 MB）
```

分区表（备份记忆）：p1 `config` 32768–65535 ｜ p2 `efi` 65536–679935 ｜ **p3 `rootfs` 679936–1678368**。
换新镜像时用 `python3` 解析 GPT 或 `fdisk -l`/`partx -o START,SECTORS "$IMG"` 重新取 `LBA_START/LBA_COUNT`。

---

## 2.（仅方式 C 需要）手动把 deb 的模块转成 OpenWrt 可用形态

如果产物已经是 `out/root/`（方式 A/B），**跳过本节**。只有拿着裸 deb 时才做：

```bash
dpkg-deb -x linux-image-${KVER}_*_arm64.deb out/root/
MODDIR=out/root/lib/modules/$KVER
( cd "$MODDIR"
  find . -name '*.ko.xz' -print0 | while IFS= read -r -d '' f; do
    xz -dc "$f" > "${f%.xz}" && rm -f "$f"; done
  for m in modules.dep modules.alias modules.symbols modules.softdep \
           modules.devname modules.order modules.builtin.modinfo; do
    [ -f "$m" ] && sed -i 's/\.ko\.xz/.ko/g' "$m"; done
  rm -f *.bin )
# 未压缩 vmlinuz 单独取（deb 里的不能用）
cp kernel/src/arch/arm64/boot/Image out/vmlinuz
```

> `post-process.sh` 就是把这个自动化了，优先用它。

---

## 3. 挂载 rootfs 分区（免 root，用 fuse2fs）

`debugfs` 只能单文件读写，替换 882 个 `.ko` 不现实；必须**挂载**。免 root 靠 `fuse2fs`。

**难点**：若宿主机（你的构建环境）里**没有 `fuse2fs` 命令**且不能 `apt install`（非 root）。
实测解法——**借 rsdk devcontainer**（里面有 root，能装 fuse2fs）：

```bash
CN=$(docker ps --format '{{.Names}}\t{{.Image}}' | awk '/rsdk/{print $1; exit}')   # 自动探测正在运行的 rsdk devcontainer

# 3.1 提取 rootfs 分区到独立 ext4 镜像文件
dd if="$IMG" of=/tmp/rp.img bs=512 skip=$LBA_START count=$LBA_COUNT status=none

# 3.2 放进容器可见路径（rsdk-src/ ↔ 容器 /workspaces/）
cp /tmp/rp.img $WS/rsdk-src/tmp-rp.img

# 3.3 容器里装 fuse2fs（一次性）+ 挂载
docker exec "$CN" bash -lc 'apt-get install -y -qq fuse2fs >/dev/null 2>&1; \
  mkdir -p /tmp/mnt-rp; fusermount -u /tmp/mnt-rp 2>/dev/null; \
  fuse2fs /workspaces/tmp-rp.img /tmp/mnt-rp && echo MOUNTED'

# 之后 MNT 在容器里 = /tmp/mnt-rp
```

> 若宿主机能拿到 root（比如换台机器/加 sudo），更简单的等价做法：
> `sudo mount -o loop,offset=$((LBA_START*512)) "$IMG" /mnt/a5e` —— 但**注意这样是直接在整盘 IMG 上挂 p3**，
> 省掉 §4 的 dd 往返。本文默认走无 root 的 rp.img 副本路线。

---

## 4. 原地替换内核四件套（在容器里对 MNT 操作）

```bash
CN=$(docker ps --format '{{.Names}}\t{{.Image}}' | awk '/rsdk/{print $1; exit}')   # 同 §3 探测
docker exec "$CN" bash -lc '
set -e
MNT=/tmp/mnt-rp
OUTW=/workspaces/radxa-a5e-openwrt-kernel/out    # 若 out/ 不在挂载内，先 cp 进 rsdk-src/
KVER='"$KVER"'

# 4.1 vmlinuz —— 未压缩 Image，覆盖同名文件
cp "$OUTW/vmlinuz" "$MNT/boot/vmlinuz-$KVER"

# 4.2 /lib/modules/<KVER> —— 整目录换掉（旧的含 .ko.xz，新的已展开+修 dep）
rm -rf "$MNT/lib/modules/$KVER"
mkdir -p "$MNT/lib/modules/$KVER"
cp -a "$OUTW/root/lib/modules/$KVER/." "$MNT/lib/modules/$KVER/"

# 4.3 dtb —— /usr/lib/linux-image-<KVER> 整目录
rm -rf "$MNT/usr/lib/linux-image-$KVER"
mkdir -p "$MNT/usr/lib/linux-image-$KVER"
cp -a "$OUTW/root/usr/lib/linux-image-$KVER/." "$MNT/usr/lib/linux-image-$KVER/"

# 4.4 删掉旧的 bridge 预加载 workaround（新内核 bridge 已 builtin，不再需要）
rm -f "$MNT/etc/init.d/bridge-modules" "$MNT/etc/rc.d/S15bridge-modules"

# 校验挂载点内容
echo "vmlinuz: $(file -b "$MNT/boot/vmlinuz-$KVER" | cut -c1-40)"
echo ".ko 数:  $(find "$MNT/lib/modules/$KVER" -name "*.ko" | wc -l)"
echo ".ko.xz:  $(find "$MNT/lib/modules/$KVER" -name "*.ko.xz" | wc -l)  (应为 0)"
ls "$MNT/usr/lib/linux-image-$KVER/allwinner/sun55i-a527-cubie-a5e.dtb" && echo "dtb ✓"
test ! -e "$MNT/etc/init.d/bridge-modules" && echo "init.d workaround 已删 ✓"
'
```

**关键**：**initrd 不动**（保留旧 `/boot/initrd.img-*`）。Debian 版 initramfs 认识 `root=UUID=`，
且新内核 bridge builtin 后，即便旧 initrd 里还嵌着旧 `bridge.ko.xz` 加载失败也**无害**（内核已自带）。

---

## 5.（只在改了 KVER 时才需要）同步 extlinux

上面四件套都按 `$KVER` 命名。**如果新内核改了版本字符串**（不再是 `6.6.98-1-aw2607`），
`/boot/extlinux/extlinux.conf` 里的 `linux/initrd/fdtdir` 路径还指向旧版本，必须同步：

```bash
docker exec "$CN" bash -lc '
  sed -i "s|/boot/vmlinuz-OLD|/boot/vmlinuz-NEW|;
          s|/boot/initrd.img-OLD|/boot/initrd.img-NEW|;
          s|linux-image-OLD|linux-image-NEW|g" /tmp/mnt-rp/boot/extlinux/extlinux.conf
  cat /tmp/mnt-rp/boot/extlinux/extlinux.conf'
```

> **initrd 版本一致性提醒**：换了 KVER 后旧 initrd 名字（`initrd.img-OLD`）与新的对不上时，
> 要么保留旧 extlinux 里的 initrd 名（旧 initrd 仍在 boot 分区），要么用新内核重新生成 initrd。
> 当前实践是**不换 KVER**（都叫 `6.6.98-1-aw2607`），所以 extlinux 完全不用动，最省事。

---

## 6. 卸载 + 写回整盘镜像 + 校验

```bash
# 6.1 容器里卸载（没有 fusermount 时直接 kill fuse2fs 进程）
docker exec "$CN" bash -lc 'sync; umount /tmp/mnt-rp 2>/dev/null || pkill -x fuse2fs; sleep 2'

# 6.2 把改好的 rp.img 拷回宿主机并写回 IMG 的 p3（conv=notrunc 只覆盖 p3 区间）
cp $WS/rsdk-src/tmp-rp.img /tmp/rp.img
dd if=/tmp/rp.img of="$IMG" bs=512 seek=$LBA_START conv=notrunc status=none

# 6.3 更新校验和
cd "$(dirname "$IMG")" && sha256sum owrt-a5e.img | tee owrt-a5e.img.sha256

# 6.4 清理临时副本
rm -f /tmp/rp.img $WS/rsdk-src/tmp-rp.img
```

---

## 7. 离线自检（不烧录就能确认镜像内文件）

```bash
dd if="$IMG" of=/tmp/verify.img bs=512 skip=$LBA_START count=$LBA_COUNT status=none

# vmlinuz 是未压缩 Image（看文件大小 ~27M，且 debugfs stat 正常）
debugfs -R "stat /boot/vmlinuz-$KVER" /tmp/verify.img 2>/dev/null | grep Size

# bridge 已 builtin
debugfs -R "cat /lib/modules/$KVER/modules.builtin" /tmp/verify.img 2>/dev/null \
  | grep -E "bridge/bridge|802/stp|llc/llc|nf_tables"

# bridge.ko 文件应"消失"
debugfs -R "ls /lib/modules/$KVER/kernel/net/bridge" /tmp/verify.img 2>/dev/null

# init.d workaround 已删
debugfs -R "stat /etc/init.d/bridge-modules" /tmp/verify.img 2>&1 | grep -q "not found" \
  && echo "workaround 已删 ✓"

# 其它固化配置没被动
debugfs -R "cat /etc/config/firewall" /tmp/verify.img 2>/dev/null | grep -c "Allow-SSH-WAN"
debugfs -R "cat /boot/extlinux/extlinux.conf" /tmp/verify.img 2>/dev/null | grep -o "coherent_pool=2M"
rm -f /tmp/verify.img
```

---

## 8. 烧录 + 板上验收

```bash
# 用户执行烧录（物理操作，assistant 不代做）
sudo dd if=owrt-a5e.img of=/dev/sdX bs=4M status=progress conv=fsync   # of= 自己核对！
```

上电拿到 WAN IP 后（SSH）：

```bash
IP=192.168.4.<动态>
ssh -o StrictHostKeyChecking=no root@$IP '
  echo "[内核]  $(uname -r)"
  echo "[builtin] /proc/modules 里应无 bridge:"
  grep -E "^bridge " /proc/modules || echo "  ✓ 空（builtin，正确）"
  echo "[sysfs]  $(ls -d /sys/module/bridge 2>/dev/null && echo 存在=builtin)"
  echo "[workaround] 已删:"; ls /etc/init.d/bridge-modules 2>&1 | head -1
  echo "[br-lan]"; ip addr show br-lan | grep -E "state|inet "
  echo "[eth0→br-lan]"; ip -d link show eth0 | grep -o "master br-lan"
'
```

判据（全绿即成功）：
- `/proc/modules` **无** `bridge`，`/sys/module/bridge` **存在** → bridge 进了 vmlinux
- `/etc/init.d/bridge-modules` **不存在** → 不再依赖 workaround
- `br-lan` 自动 `state UP` + `192.168.1.1` + `eth0 master br-lan` → LAN 开箱可用

---

## 9. 回退

任何一步搞砸，直接用上一版备份覆盖回去：

```bash
cp owrt-a5e.img.bak-initd owrt-a5e.img      # 回退到 init.d 预加载那版
# 或每次替换前先备份当前版：
cp owrt-a5e.img owrt-a5e.img.bak-$(date +%Y%m%d-%H%M)
```

**建议养成习惯**：§3 挂载前先 `cp "$IMG" "$IMG.bak-$(date +%Y%m%d-%H%M)"`，改坏了能秒回。

---

## 10. 坑位速查（本文特有）

| 现象 | 原因 | 处理 |
|---|---|---|
| 烧进去启动卡住 / vmlinuz 加载失败 | 用了 deb 里 gzip 的 vmlinuz | §0：必须用 `arch/arm64/boot/Image`（未压缩） |
| `fuse2fs: command not found` | 宿主机无 root 装不了 | §3：借 devcontainer 跑 |
| 改了 KERNEL_URL/版本但镜像没变 | Actions cache 命中旧 clone | 编译仓库 cache key 已含 `scripts/**`；本地就 `rm -rf out/` 重来 |
| `br-lan` 又建不起来、`/proc/modules` 无 bridge 但也起不来 | 新内核实际没把 bridge builtin（fragment 没生效） | §7 查 `modules.builtin` 有没有 `kernel/net/bridge/bridge.ko`；没有就回编译仓库查 fragment |
| KVER 变了后起不来 | extlinux 路径没同步 | §5 |
| 写回后镜像损坏 | `dd seek` 用错 LBA | 核对 §1 `LBA_START`；先做 §9 备份 |

---

## 11. 完整流程一图流

```
[编译仓库 radxa-a5e-openwrt-kernel]
   build.sh → post-process.sh → verify.sh → out/{vmlinuz, root/lib/modules, root/usr/lib/linux-image-*}
                     (或下载 Actions artifact 得到 out/)
                                   │
                                   ▼
[主项目 本文件]
   §9 备份 IMG
   §3 dd 取 p3 → cp 进容器 → fuse2fs 挂载
   §4 替换四件套（vmlinuz / modules / dtb / 删 init.d workaround）；initrd 不动
   §5 (改 KVER 才做) 同步 extlinux
   §6 卸载 → dd 写回 → sha256
   §7 debugfs 离线自检
   §8 烧录 → 板上验收（bridge builtin + 无 workaround + br-lan UP）
```

> 每次内核有改动（补新 builtin CONFIG、跟进上游），走一遍 §3→§8 即可，rootfs 里其它定制全程零改动。
