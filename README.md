# CatDrive-Disk-Auto-Sleep

猫盘自动硬盘休眠改善，支持大/小猫盘群晖 DSM 7.x（DS120j/DS119j）

## curl一键安装

ssh登录后`sudo -i`切换到root

```sh
curl -sSL https://raw.githubusercontent.com/SadYuyuko/CatDrive-Disk-Auto-Sleep/main/catdisk-sleep.sh | sudo sh -s install
```

## 临时生效（不安装、不写入开机自启）

```sh
curl -sSL https://raw.githubusercontent.com/SadYuyuko/CatDrive-Disk-Auto-Sleep/main/catdisk-sleep.sh | sudo sh -s run
```

## 其他命令

| 命令 | 说明 |
| --- | --- |
| `status` | 查看休眠/唤醒相关状态（磁盘、SCSI 监控、WOL、日志） |
| `sleep-now` | 立即强制硬盘待机（需要 `hdparm`/`sdparm`） |
| `wake` | 立即唤醒硬盘 |
| `wol-on` | 网卡只保留 magic-packet 唤醒 |
| `wol-off` | 关闭WOL唤醒（注意 |
| `arp` | 禁用 IP 冲突检测并预热 arping |
| `logquiet` | 调大 logrotate 阈值 |
| `diag` | 诊断每小时启停是整机唤醒还是硬盘唤醒 |

例如查看状态：

```sh
curl -sSL https://raw.githubusercontent.com/SadYuyuko/CatDrive-Disk-Auto-Sleep/main/catdisk-sleep.sh | sudo sh -s status
```

## 卸载

```sh
curl -sSL https://raw.githubusercontent.com/SadYuyuko/CatDrive-Disk-Auto-Sleep/main/catdisk-sleep.sh | sudo sh -s uninstall
```

卸载会移除开机自启钩子 `/usr/local/etc/rc.d/S99catdisk-sleep.sh` 与已安装脚本，并恢复群晖原厂的 `pkg-scsit-monitor.service`。

## 日志

运行日志写入 `/var/log/catdisk-sleep.log`，开机自启通过 `/usr/local/etc/rc.d/S99catdisk-sleep.sh`（DSM 开机时以 `start` 参数执行 `S*.sh`，脚本内以 `# catdisk-sleep-boot` 标记）。

## 原理

群晖的 `synoscsitmonitor` / `pkg-scsit-monitor.service`（SCSI 监控/轮询）和 `arping`（IP 冲突检测）会周期性读取硬盘，不断重置硬盘空闲计时器，导致 DSM 的硬盘休眠永远无法触发。  
脚本在开机时移除SCSI轮询并额外：

- 开启内核 `manage_start_stop` / `power/control=auto`，让 ATA 待机指令真正停转
- 网卡只保留 **magic-packet** 唤醒，避免 WOL 被路由探活 / DHCP 续租 / mDNS 等误唤醒
- 禁用 IP 冲突检测（`syno_ip_conflict_detect` / `arping`）
- 将 `logrotate` 阈值从 1M 扩大至 8M ，原日志达到 1M 时（约 1 小时）会触发轮转读写 `.SYNO*DB` 数据库，使硬盘间歇性自动唤醒
- 开机自启使用 `/usr/local/etc/rc.d/`（DSM 开机时执行其中 `S*.sh` 的 `start` 参数），DSM 7 开机不执行 `/etc/rc.local`，故不再用 rc.local 自启

### DSM 休眠判定机制

DSM 通过内核计数 `/sys/block/sda/device/syno_idle_time` 累计硬盘的"纯空闲秒数"，需要**连续**达到 `standbytimer`（休眠时间阈值）才会发出 ATA 待机指令。任何一次磁盘读写都会把该计数清零，因此休眠能否触发取决所设置的休眠时间内是否有连接或进程读写。

## 注意

- 硬盘休眠依赖网卡低功耗监听唤醒，大小猫盘在硬盘休眠上逻辑一致，**关闭 WOL 会导致休眠失效**，请保持 WOL 开启（脚本默认）
- 休眠计时不可超过 20 分钟，DSM 自身的磁盘空间检查以约 20 分钟为周期，与空闲计时器冲突导致无限打断休眠计划，建议设 15 分钟
- 不要安装 qBittorrent 等常驻进程插件，会导致猫盘内存紧张触发 kswapd 持续把内存换页写 swap，等于每几十秒触盘一次导致无法休眠
- DSM 通常周四凌晨会运行约 1 小时的每周例行维护批次（`syno_disk_db_update`、`synolegalnotifier` 等），期间无法休眠属正常现象

## 效果

<img width="600" height="189" alt="0" src="https://github.com/user-attachments/assets/cc8adc4d-5801-4340-96dd-2f185b7aa6e9" />

访问网页面板或远程连接时出现`Internal disks woke up from hibernation.`即脚本生效
