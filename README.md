[English](README.md) | [繁體中文](README.zh-TW.md)

# disk-health-check

A monthly disk health check for Windows. On the 1st of each month (or at the next logon if the PC was off) it shows a toast notification asking whether to check all local disks. If you click "Start scan" (開始掃描), it runs in the background and writes an HTML report.

## What it checks

1. **SMART** of all disks, read through [CrystalDiskInfo](https://crystalmark.info/en/software/crystaldiskinfo/) (`/CopyExit`). Its health verdict and your custom thresholds are used.
2. **Key attributes compared with the last run**: for HDDs reallocated / pending / uncorrectable sectors and CRC errors; for NVMe critical warning, media errors, percentage used and available spare. The report flags whether they increased.
3. **Online file system scan**: `Repair-Volume -Scan` on every NTFS volume. It is read-only, does not lock the volume, and you can keep using the PC (about 25 minutes in total in the author's setup).
4. **System event log**: warnings and errors from disk / Ntfs / stornvme etc. since the last check (bad-block style events are highlighted).

## Requirements

- Windows with Windows PowerShell 5.1 (developed and used on Windows 11; other versions are untested).
- **Administrator rights**: `install.ps1` asks for UAC once to register the scheduled tasks. The scan itself runs from a scheduled task with highest privileges, so no UAC prompt appears at scan time.
- **CrystalDiskInfo** (not included). Download the portable (zip) edition from <https://crystalmark.info/en/software/crystaldiskinfo/> (source: <https://github.com/hiyohiyo/CrystalDiskInfo>; MIT license). Extract it so that `DiskInfo64.exe` is in a `CrystalDiskInfo` folder next to these scripts, or put it anywhere and set the user environment variable `DISKHEALTH_CDI_DIR` to that folder. The folder must be writable, because CrystalDiskInfo writes `DiskInfo.txt` into it. `DiskInfo64.exe`, `DiskInfo64S.exe` and `DiskInfo64K.exe` are looked for, in that order.

## Install

1. Put the folder somewhere permanent (the scheduled tasks point to this location) and place CrystalDiskInfo as described above.
2. Run `install.ps1` (right-click > Run with PowerShell, or `powershell -ExecutionPolicy Bypass -File install.ps1`). Accept the UAC prompt.
3. If you move the folder or change the CrystalDiskInfo location later, run `install.ps1` again.

## Use

- Wait for the monthly notification, or start a check right now: double-click `立即健檢.cmd`, or run `Start-ScheduledTask -TaskPath '\硬碟健檢\' -TaskName '執行掃描'`.
- Preview the question notification: `.\notify.ps1 -Force`.
- Open the latest report: double-click `開啟最新報告.cmd`, or press "open report" in the completion notification. Reports are saved as `reports\硬碟健檢_<date>.html`.
- Notification buttons: **開始掃描** (start scan) starts the scan task; **延後** (postpone) quietly puts the notification back in the Action Center so you can start it later.

The UI text of the notifications and the report is in Traditional Chinese.

## What it leaves on your system

- Two scheduled tasks under `\硬碟健檢\`: `每月提醒` (1st of every month 10:00 + at each logon with a 3-minute delay; runs `notify.ps1`, asks only if this month has not been checked) and `執行掃描` (runs `health_check.ps1` with highest privileges, 6-hour limit).
- Registry keys under `HKCU` only: the `diskhealth:` URL protocol (`HKCU:\Software\Classes\diskhealth`) and the notification source (`HKCU:\Software\Classes\AppUserModelId\DiskHealthCheck.Tool`).
- Toast notifications from "硬碟健檢".
- Files in this folder: `data\` (`state.json`, a `scan_*.json` per run, raw CrystalDiskInfo output, `health_check.log`) and `reports\` (HTML reports). They contain your disk serial numbers and health data, so they are git-ignored. CrystalDiskInfo also writes `DiskInfo.txt` in its own folder.
- The scan only reads: it uses `Repair-Volume -Scan` and never repairs or locks a volume.

## Uninstall

Run `uninstall.ps1` (asks for UAC). It removes the two scheduled tasks, the `diskhealth:` protocol and the notification source. Reports and data are kept; delete the folder yourself if you want them gone.

## Files

| File | Purpose |
|---|---|
| `install.ps1` / `uninstall.ps1` | Register / remove tasks, protocol and notification source |
| `register_user.ps1` | Registers the protocol and notification source (HKCU) |
| `health_check.ps1` | The health check itself (needs administrator) |
| `notify.ps1` | Shows the question notification; `-Force` asks even if this month is done |
| `handler.ps1` | Handles the notification buttons |
| `common.ps1` | Shared settings and functions |
| `launcher.vbs` | Starts PowerShell without a console window |

## License

[MIT](LICENSE). CrystalDiskInfo is a separate project with its own license and is not distributed here.
