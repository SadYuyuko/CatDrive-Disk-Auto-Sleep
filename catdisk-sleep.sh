#!/bin/sh
# CatDrive-Disk-Auto-Sleep  猫盘自动硬盘休眠脚本

RAW_URL="https://raw.githubusercontent.com/SadYuyuko/CatDrive-Disk-Auto-Sleep/main/catdisk-sleep.sh"
DEST="/usr/local/bin/catdisk-sleep.sh"
HOOK="/usr/local/etc/rc.d/S99catdisk-sleep.sh"

IFACE="eth0"
DISK=""
LOG="/var/log/catdisk-sleep.log"

# 开机时自动把网卡设为仅 magic-packet 唤醒
WOL_MAGIC_ON_BOOT=1

# 开机时自动禁用会周期性触盘的 IP 冲突检测(arping)
QUIET_ARPING_ON_BOOT=1

# 调大 logrotate 阈值,减少日志轮转写库导致的周期唤醒(默认开)
LOGQUIET_ON_BOOT=1

usage(){
  echo "用法: sh catdisk-sleep.sh <-install|-uninstall|-status|-sleep-now|-wake|-wol-on|-wol-off|-arp|-logquiet|-diag>"
  echo "  -arp      禁用 IP 冲突检测并预热 arping(防周期性磁盘读取)"
  echo "  -logquiet 调大 logrotate 阈值(1M->8M, 减少日志轮转触盘唤醒)"
}

log(){
  echo "$(date '+%F %T') $*" >> "$LOG" 2>/dev/null
}

detect_disk(){
  [ -n "$DISK" ] && return
  if command -v synodisk >/dev/null 2>&1; then
    DISK=$(synodisk --enum 2>/dev/null | grep -m1 -E '^/dev/sd[0-9a-z]+')
  fi
  [ -n "$DISK" ] || DISK=$(ls /dev/sd? 2>/dev/null | head -n1)
  [ -n "$DISK" ] || DISK=/dev/sda
}

# 去除重置硬盘空闲计时器的 SCSI 监控
stop_pollers(){
  if pgrep -x synoscsitmonitor >/dev/null 2>&1; then
    killall -9 synoscsitmonitor 2>/dev/null
    log "kill synoscsitmonitor"
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop pkg-scsit-monitor.service 2>/dev/null
    systemctl disable pkg-scsit-monitor.service 2>/dev/null
    log "stop/disable pkg-scsit-monitor.service"
  fi
}

# 允许内核执行 stop-start 待机(ARM 平台默认关闭)
enable_manage_start_stop(){
  for f in /sys/class/scsi_disk/*/manage_start_stop; do
    [ -e "$f" ] && echo 1 > "$f" 2>/dev/null
  done
  for f in /sys/block/sd*/device/power/control; do
    [ -e "$f" ] && echo auto > "$f" 2>/dev/null
  done
  log "enable manage_start_stop / power/control=auto"
}

# 立即强制硬盘待机
sleep_now(){
  detect_disk
  if command -v hdparm >/dev/null 2>&1; then
    hdparm -y "$DISK" 2>&1 | tee -a "$LOG"
  elif command -v sdparm >/dev/null 2>&1; then
    sdparm --command=stop "$DISK" 2>&1 | tee -a "$LOG"
  else
    log "无 hdparm/sdparm, 跳过强制待机; 请在 DSM 控制面板设置硬盘休眠时间"
    return 1
  fi
}

# 唤醒硬盘
wake_disk(){
  detect_disk
  dd if="$DISK" bs=512 count=1 of=/dev/null 2>/dev/null
  log "wake disk $DISK"
}

# 防误唤醒 网卡只保留 magic-packet
wol_magic_only(){
  if command -v ethtool >/dev/null 2>&1; then
    ethtool -s "$IFACE" wol g 2>>"$LOG"
    log "ethtool $IFACE wol g (仅 magic packet)"
  else
    log "ethtool 不存在, 无法设置唤醒过滤"
  fi
}

# 抑制 arping 周期性磁盘读取
disable_arping_poll(){
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable ip-conflict-detect.service 2>>"$LOG"
    systemctl stop ip-conflict-detect.service 2>>"$LOG"
    log "disable/stop ip-conflict-detect.service (防 arping 周期读盘)"
  fi
  pkill -x syno_ip_conflict_detect 2>/dev/null
  if command -v vmtouch >/dev/null 2>&1; then
    for a in /sbin/arping /usr/sbin/arping; do
      [ -f "$a" ] && vmtouch -t "$a" 2>/dev/null
    done
  fi
  log "warm arping page cache"
}

wol_off(){
  if command -v ethtool >/dev/null 2>&1; then
    ethtool -s "$IFACE" wol d 2>>"$LOG"
    log "ethtool $IFACE wol d (关闭WOL; 注意可能连带硬盘休眠失效)"
  fi
}

# 调大 logrotate 阈值: 群晖 synologrotated 周期性运行 logrotate,
# 默认按 size 1M 轮转日志并写 .SYNO*DB 数据库, 每次都会触盘唤醒。
# 将默认 size 1M 调大到 8M, 显著拉长两次磁盘写入间隔(实测 ~1h -> 2.5h+)。
logquiet(){
  local changed=0
  for cfg in /etc/logrotate.conf /etc/logrotate.d/synolog; do
    if [ -f "$cfg" ] && grep -qE '^\s*size 1M' "$cfg"; then
      sed -i 's/^\s*size 1M/size 8M/' "$cfg"
      log "logrotate $cfg: size 1M -> 8M"
      echo "  $cfg: size 1M -> 8M"
      changed=1
    fi
  done
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart synologrotated.service 2>/dev/null
    log "restart synologrotated.service"
  fi
  [ "$changed" = "1" ] || { echo "  logrotate 阈值已是 8M 或无匹配, 无需改动"; }
  echo "  完成: 日志轮转阈值已调大到 8M, 减少周期唤醒"
}

# 状态查看
show_status(){
  echo "== 磁盘 =="
  detect_disk
  echo "  磁盘: $DISK"
  if command -v hdparm >/dev/null 2>&1; then hdparm -C "$DISK" 2>/dev/null; fi

  echo "== SCSI 监控进程(应为未运行) =="
  pgrep -l synoscsitmonitor 2>/dev/null || echo "  synoscsitmonitor 未运行(正常)"
  systemctl is-active pkg-scsit-monitor.service 2>/dev/null | sed 's/^/  pkg-scsit-monitor: /' || true

  echo "== 网络唤醒 =="
  ethtool "$IFACE" 2>/dev/null | grep -iE 'wake' || echo "  ethtool 不可用"

  echo "== IP 冲突检测(应为未运行) =="
  if command -v systemctl >/dev/null 2>&1; then
    systemctl is-enabled ip-conflict-detect.service 2>/dev/null | sed 's/^/  ip-conflict-detect: /' || echo "  ip-conflict-detect: 未启用(正常)"
  fi
  pgrep -l arping 2>/dev/null || echo "  arping 未运行(正常)"

  echo "== 内存/swap =="
  if command -v free >/dev/null 2>&1; then free -m 2>/dev/null | grep -E 'Mem|Swap'; fi

  echo "== logrotate 阈值 =="
  grep -hE '^\s*size' /etc/logrotate.conf /etc/logrotate.d/synolog 2>/dev/null | sed 's/^/  /' || echo "  无配置"

  echo "== 休眠日志(最近10条) =="
  tail -n 10 "$LOG" 2>/dev/null || echo "  无日志"
}

# 诊断每小时启停
diag(){
  echo "1) 系统开机时间记录(若每小时出现一条新的 reboot 记录 => 整机被 WOL 唤醒):"
  last -n 30 reboot 2>/dev/null | head -n 30
  echo
  echo "2) 当前 uptime(多次运行对比, 若被清零说明整机重启过):"
  cat /proc/uptime
  echo
  echo "3) 网卡链路(猫盘关机后链路仍在线=MCU 在监听 WOL):"
  ethtool "$IFACE" 2>/dev/null | grep -i link
  echo
  echo "4) 内核唤醒源:"
  dmesg 2>/dev/null | grep -iE 'wake|resume|wol' | tail -n 30
  echo
  echo "5) 若只是硬盘频繁起停而非整机重启, 请用 htop/iotop 定位每小时触盘进程,"
  echo "   并检查 DSM 计划任务(控制面板->任务计划)是否有每小时任务。"
  echo
  echo "6) 已知的周期性触盘来源(会重置 syno_idle_time 导致无法休眠):"
  echo "   - syno_ip_conflict_detect/arping: IP 冲突检测, 每次运行都会从磁盘读回二进制 (可执行本脚本 -arp 处理)"
  echo "   - kswapd0: 内存不足时持续换页写 swap (常见于常驻大内存程序: qBittorrent/SynoFinder/postgres 等)"
  echo "   - DSM 每周(通常周四凌晨 00:38)例行维护批次: synostgvolume/syno_disk_db_update 等约 1 小时, 属正常"
  echo "   - 用户自己的 SSH/网页/FileStation 会话: 任何磁盘访问都会重置空闲计时器"
  echo
  echo "  磁盘空闲计数 /sys/block/sda/device/syno_idle_time 需连续 >= standbytimer 才能触发休眠"
}


# 开机自启写入 /usr/local/etc/rc.d
install_boot_hook(){
  mkdir -p /usr/local/etc/rc.d
  cat > "$HOOK" <<EOF
#!/bin/sh
# catdisk-sleep-boot
case "\$1" in
  start|'') $DEST --boot ;;
  stop) ;;
  *) ;;
esac
exit 0
EOF
  chmod 755 "$HOOK"
  echo "已写入开机自启: $HOOK"
  # 清理旧的 /etc/rc.local 钩子(DSM7 不执行该文件)
  if [ -f /etc/rc.local ]; then
    sed -i '/catdisk-sleep-boot/d' /etc/rc.local 2>/dev/null
  fi
}
install_boot(){
  echo "下载脚本到 $DEST ..."
  mkdir -p /usr/local/bin
  # 优先用本地文件(本次运行的脚本)
  if [ -f "$0" ] && [ "$(basename "$0" 2>/dev/null)" = "catdisk-sleep.sh" ]; then
    cp -f "$0" "$DEST"
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$DEST" "$RAW_URL" || { echo "下载失败: $RAW_URL"; return 1; }
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$DEST" "$RAW_URL" || { echo "下载失败: $RAW_URL"; return 1; }
  else
    echo "未找到 curl/wget, 请手动把脚本放到 $DEST"; return 1
  fi
  chmod 755 "$DEST"
  install_boot_hook
  # 立即执行一次
  stop_pollers; enable_manage_start_stop
  [ "$WOL_MAGIC_ON_BOOT" = "1" ] && wol_magic_only
  [ "$QUIET_ARPING_ON_BOOT" = "1" ] && disable_arping_poll
  [ "$LOGQUIET_ON_BOOT" = "1" ] && logquiet
  echo "安装完成: $DEST"
  echo "重启后自动生效。"
}

# 卸载
uninstall(){
  sed -i '/catdisk-sleep-boot/d' /etc/rc.local 2>/dev/null
  rm -f "$HOOK"
  echo "已移除开机自启 ($HOOK)"
  rm -f "$DEST"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable pkg-scsit-monitor.service 2>/dev/null
    systemctl start pkg-scsit-monitor.service 2>/dev/null
    echo "已恢复 pkg-scsit-monitor.service"
    systemctl enable ip-conflict-detect.service 2>/dev/null
    systemctl start ip-conflict-detect.service 2>/dev/null
    echo "已恢复 ip-conflict-detect.service"
  fi
  # 恢复 logrotate 阈值
  for cfg in /etc/logrotate.conf /etc/logrotate.d/synolog; do
    if [ -f "$cfg" ] && grep -qE '^\s*size 8M' "$cfg"; then
      sed -i 's/^\s*size 8M/size 1M/' "$cfg"
      echo "已恢复 $cfg: size 8M -> 1M"
    fi
  done
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart synologrotated.service 2>/dev/null
  fi
  echo "卸载完成。"
}

# 参数解析
CMD="run"
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help|help)  usage; exit 0 ;;
    --boot)          CMD=boot ;;
    -run|run|start)  CMD=run ;;
    -install|install)  CMD=install ;;
    -uninstall|uninstall) CMD=uninstall ;;
    -status|status)  CMD=status ;;
    -sleep-now|sleep-now)  CMD=sleep_now ;;
    -wake|wake)      CMD=wake ;;
    -wol-on|wol-on)  CMD=wol_on ;;
    -wol-off|wol-off) CMD=wol_off ;;
    -arp|arp)        CMD=arp ;;
    -logquiet|logquiet)  CMD=logquiet ;;
    -diag|diag)      CMD=diag ;;
    stop)            : ;;
    *)               echo "未知参数: $1"; usage; exit 1 ;;
  esac
  shift
done

# 只读命令允许非 root
case "$CMD" in
  status|diag) : ;;
  *) [ "$(id -u)" = "0" ] || { echo "请以 root 运行 (sudo sh $0 ...)"; exit 1; } ;;
esac

case "$CMD" in
  run)      stop_pollers; enable_manage_start_stop
            [ "$QUIET_ARPING_ON_BOOT" = "1" ] && disable_arping_poll
            [ "$LOGQUIET_ON_BOOT" = "1" ] && logquiet
            log "hdd-sleep run" ;;
  boot)     stop_pollers; enable_manage_start_stop
            [ "$WOL_MAGIC_ON_BOOT" = "1" ] && wol_magic_only
            [ "$QUIET_ARPING_ON_BOOT" = "1" ] && disable_arping_poll
            [ "$LOGQUIET_ON_BOOT" = "1" ] && logquiet
            log "hdd-sleep boot" ;;
  install)  install_boot ;;
  uninstall) uninstall ;;
  status)   show_status ;;
  sleep_now) sleep_now ;;
  wake)     wake_disk ;;
  wol_on)   wol_magic_only ;;
  wol_off)  wol_off ;;
  arp)      disable_arping_poll; echo "已禁用 IP 冲突检测并预热 arping"; log "arp quiet" ;;
  logquiet) logquiet ;;
  diag)     diag ;;
esac
