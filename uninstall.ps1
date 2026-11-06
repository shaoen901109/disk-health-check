# 移除排程、協定與通知來源（報告與資料保留）
. "$PSScriptRoot\common.ps1"
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}
foreach ($t in $PromptTask, $ScanTask) { Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue }
Remove-Item "HKCU:\Software\Classes\$Proto" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "HKCU:\Software\Classes\AppUserModelId\$AppId" -Recurse -Force -ErrorAction SilentlyContinue
Write-Host '已移除。'
