# 註冊通知來源與 diskhealth: 協定（只動目前使用者的 HKCU，不需管理員）
. "$PSScriptRoot\common.ps1"
$ErrorActionPreference = 'Stop'

$k = "HKCU:\Software\Classes\AppUserModelId\$AppId"
New-Item $k -Force | Out-Null
Set-ItemProperty $k DisplayName '硬碟健檢'
Set-ItemProperty $k ShowInSettings 1

# diskhealth: 協定 → handler.ps1（通知按鈕、立即健檢.cmd、開啟最新報告.cmd 用）
$k = "HKCU:\Software\Classes\$Proto"
New-Item "$k\shell\open\command" -Force | Out-Null
Set-ItemProperty $k '(default)' 'URL:Disk Health Check'
Set-ItemProperty $k 'URL Protocol' ''
Set-ItemProperty "$k\shell\open\command" '(default)' "wscript.exe `"$(Join-Path $Root 'launcher.vbs')`" handler.ps1 `"%1`""
Write-Host '已註冊通知來源與 diskhealth: 協定'