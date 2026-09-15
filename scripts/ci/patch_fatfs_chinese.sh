#!/bin/sh
#=============================================================================
# wLaunchELF_ISR (A9VG 汉化版) — USB / BDM 驱动校验脚本 v21
#-----------------------------------------------------------------------------
# 关键结论（2026-09-15 排查 USB 看不到文件的根因后定稿）:
#
#   之前 USB 看不到文件，根因有两层：
#     1) 本仓库 iop/__precompiled/ 缺少 bdm / bdmfs_fatfs / usbmass_bd 三个
#        驱动（它们本应由 israpps 上游提交），导致 EE 构建时 embed.make 找不到
#        可嵌入的 USB 驱动；
#     2) 旧版（v3~v5）补丁脚本又用老工具链（GCC 3.2.3）从 ps2sdk master 源码
#        把这些驱动「重编」了一遍，产物是坏二进制（master 源码是 C99/C11，
#        与 GCC 3.2.3 不兼容；-fstrict-aliasing 还会破坏 FatFs 的类型双关），
#        并覆盖回 iop/__precompiled/，于是「进得了 mass:/ 但列不出文件」。
#
#   R3Z 之所以能正常识别 U 盘，是因为它用现代工具链镜像里的预编译驱动；而
#   israpps 上游原本就是把一套「已验证可用」的 iop/__precompiled/*.irx
#   （含 bdm / bdmfs_fatfs / usbmass_bd，支持 exFAT + UTF-8 长文件名）直接提交进
#   仓库，EE 构建时 embed.make 用 bin2s 把它们编进 ELF，不再从源码重编。
#
#   因此本脚本（v21）只做一件事：校验仓库里提交的 USB/BDM 驱动是否就位且正常。
#   —— 不做任何源码重编、不下载、不覆盖任何 .irx 文件。
#   这正是原版/上游的做法，也是 R3Z 能工作的做法。
#
#   纯 POSIX sh 编写，既能被 CI 的 `bash` 调用，也能直接 `sh` 运行。
#
# 校验通过 = 驱动齐全且体积/特征正常 -> 返回 0，CI 继续出包。
# 校验失败 = 任一必需驱动缺失或体积异常 -> 返回 1，CI 停止出包（避免交出坏包）。
# 如需强制跳过，可在 workflow 设 skip_driver_check=true，或设 ALLOW_MISSING_DRIVERS=1。
#=============================================================================

echo "=========================================="
echo "USB/BDM driver verification script (A9VG ISR edition v21)"
PS2SDK="${PS2SDK:-/usr/local/ps2dev/ps2sdk}"
WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"
IRX_DIR="$WORKSPACE/iop/__precompiled"
[ -d "$IRX_DIR" ] || IRX_DIR="$WORKSPACE/../iop/__precompiled"
echo "Using PS2SDK    = $PS2SDK"
echo "Using WORKSPACE = $WORKSPACE"
echo "Using IRX_DIR   = $IRX_DIR"
echo "=========================================="

# 最小体积阈值（字节）。取 israpps 上游提交的真值下限，足以筛掉「重编坏掉的几 KB 残骸」。
# 用法: min_size <name.irx>  -> 输出下限，找不到就输出 0
min_size() {
  case "$1" in
    bdm.irx)          echo 3000 ;;
    bdmfs_fatfs.irx)  echo 20000 ;;
    usbmass_bd.irx)   echo 5000 ;;
    ps2smap.irx)      echo 8000 ;;
    *)                echo 0 ;;
  esac
}

# CP936（简体中文 GBK）版 bdmfs_fatfs.irx 的体积下限。
# 上游默认版仅 ~37724 字节（CODE_PAGE=869 希腊，无中文长名），
# CP936 版因内嵌 GBK 双向码表（uni2oem936/oem2uni936 各约 87KB）约 210KB。
# 低于此阈值即视为「未开启中文长名」，USB 里的中文名会退化成 ~1 短名。
CP936_MIN_SIZE=150000

# 需要包含的特征字符串（用于区分「上游 exFAT 版」与别的版本），没有则为空。
need_string() {
  case "$1" in
    bdmfs_fatfs.irx)  echo "exFAT" ;;
    *)                echo "" ;;
  esac
}

rc=0

echo "--- 必需 USB/BDM 驱动 (EXFAT=1 构建一定用到) ---"
for irx in bdm.irx bdmfs_fatfs.irx usbmass_bd.irx; do
  f="$IRX_DIR/$irx"
  if [ ! -f "$f" ]; then
    echo "ERROR: 缺少必需驱动 $f （上游 israpps/wLaunchELF_ISR 应在 iop/__precompiled/ 提交此文件）" >&2
    rc=1
    continue
  fi
  sz=$(wc -c < "$f" | tr -d ' ')
  min=$(min_size "$irx")
  if [ "$sz" -lt "$min" ]; then
    echo "ERROR: $irx 体积异常（${sz} 字节 < 下限 ${min} 字节），疑似被坏二进制覆盖" >&2
    rc=1
    continue
  fi
  pat=$(need_string "$irx")
  if [ -n "$pat" ]; then
    if grep -aq "$pat" "$f" 2>/dev/null; then
      if [ "$irx" = "bdmfs_fatfs.irx" ] && [ "$sz" -lt "$CP936_MIN_SIZE" ]; then
        echo "WARN: $irx (${sz} 字节) 含 '${pat}' 但体积偏小 -> 疑似上游 CP869 默认版（无中文长名），"
        echo "       USB 里的简体中文文件名会退化成 ~1 短名。请替换为 CP936(GBK) 预编译版（约 210KB）。"
      else
        echo "OK: $irx (${sz} 字节, 含 '${pat}' 特征 -> 支持 exFAT/长名)"
        if [ "$irx" = "bdmfs_fatfs.irx" ]; then
          echo "     体积 >= ${CP936_MIN_SIZE} 字节 -> 已启用 CP936(GBK) 代码页，中文长名可完整显示。"
        fi
      fi
    else
      echo "WARN: $irx (${sz} 字节) 未检出 '${pat}' 特征，可能不是上游 exFAT 版驱动"
    fi
  else
    echo "OK: $irx (${sz} 字节)"
  fi
done

echo "--- 建议存在的网络驱动 (默认 ETH=1 需要；ETH=0 可缺) ---"
for irx in ps2smap.irx; do
  f="$IRX_DIR/$irx"
  if [ -f "$f" ]; then
    sz=$(wc -c < "$f" | tr -d ' ')
    echo "OK: $irx (${sz} 字节)"
  else
    echo "WARN: 未找到 $f —— 默认 ETH=1 构建会失败；如需网络功能请从上游提交此文件，或显式 ETH=0 构建"
  fi
done

echo "--- 其它 embed.make 直接引用的预编译驱动 (MX4SIO/MMCE/XFROM/mc/iomanX/fileXio/cdfs) ---"
for irx in mx4sio_bd.irx mmceman.irx extflash.irx xfromman.irx \
           mcman.irx mcserv.irx sio2man.irx iomanX.irx fileXio.irx cdfs.irx; do
  f="$IRX_DIR/$irx"
  if [ -f "$f" ]; then
    sz=$(wc -c < "$f" | tr -d ' ')
    echo "OK: $irx (${sz} 字节)"
  else
    echo "WARN: 未找到 $f （对应某构建选项所需的驱动）"
  fi
done

echo "=========================================="
if [ "$rc" -ne 0 ]; then
  echo "USB/BDM 驱动校验失败：必需驱动缺失或异常，停止出包。"
  echo "（如需无论如何继续，可在 workflow 设 skip_driver_check=true，或设 ALLOW_MISSING_DRIVERS=1）"
  if [ "${ALLOW_MISSING_DRIVERS:-0}" != "1" ]; then
    exit 1
  fi
  echo "（已设 ALLOW_MISSING_DRIVERS=1，放行）"
fi
echo "USB/BDM 驱动校验通过：将直接使用仓库提交的预编译驱动，不重编。"
echo "=========================================="
exit 0
