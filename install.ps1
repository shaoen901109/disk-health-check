# 安裝：註冊通知來源、diskhealth: 協定、兩個排程工作（需系統管理員，會自動要求 UAC）
. "$PSScriptRoot\common.ps1"
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $p = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit $p.ExitCode
}
$ErrorActionPreference = 'Stop'
$user = "$env:USERDOMAIN\$env:USERNAME"
$launcher = Join-Path $Root 'launcher.vbs'

# 通知來源與 diskhealth: 協定（全在 HKCU）
& "$Root\register_user.ps1"

function TaskXml($desc, $triggers, $runLevel, $limit, $script) {
    @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Author>$user</Author><Description>$desc</Description></RegistrationInfo>
  <Triggers>$triggers</Triggers>
  <Principals><Principal id="Author"><UserId>$user</UserId><LogonType>InteractiveToken</LogonType><RunLevel>$runLevel</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <ExecutionTimeLimit>$limit</ExecutionTimeLimit>
    <Priority>7</Priority>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author"><Exec><Command>wscript.exe</Command><Arguments>"$launcher" $script</Arguments></Exec></Actions>
</Task>
"@
}

$next1st = (Get-Date -Day 1).Date.AddMonths(1).AddHours(10).ToString('s')
$months = '<January/><February/><March/><April/><May/><June/><July/><August/><September/><October/><November/><December/>'
$promptTriggers = @"
<CalendarTrigger><StartBoundary>$next1st</StartBoundary><Enabled>true</Enabled>
  <ScheduleByMonth><DaysOfMonth><Day>1</Day></DaysOfMonth><Months>$months</Months></ScheduleByMonth></CalendarTrigger>
<LogonTrigger><Enabled>true</Enabled><UserId>$user</UserId><Delay>PT3M</Delay></LogonTrigger>
"@

Register-ScheduledTask -TaskPath $TaskPath -TaskName $PromptTask -Force -Xml (TaskXml `
    '每月 1 號 10:00 跳出通知詢問是否進行硬碟健檢；當天沒開機則於下次登入時補問（本月已健檢就不問）。' `
    $promptTriggers 'LeastPrivilege' 'PT10M' 'notify.ps1') | Out-Null

Register-ScheduledTask -TaskPath $TaskPath -TaskName $ScanTask -Force -Xml (TaskXml `
    '硬碟健檢本體（SMART + 檔案系統掃描 + 事件記錄），由通知的「開始掃描」按鈕觸發，以最高權限執行。' `
    '' 'HighestAvailable' 'PT6H' 'health_check.ps1') | Out-Null

Write-Host "安裝完成：排程 $TaskPath$PromptTask、$TaskPath$ScanTask"
