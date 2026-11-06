# 共用設定與函式（被其他腳本 dot-source）
$Root       = $PSScriptRoot
$AppId      = 'DiskHealthCheck.Tool'
$Proto      = 'diskhealth'
$TaskPath   = '\硬碟健檢\'
$PromptTask = '每月提醒'
$ScanTask   = '執行掃描'
$DataDir    = Join-Path $Root 'data'
$ReportDir  = Join-Path $Root 'reports'
$StateFile  = Join-Path $DataDir 'state.json'
# CrystalDiskInfo (portable zip) folder. Default: .\CrystalDiskInfo next to these scripts.
# Override with the user environment variable DISKHEALTH_CDI_DIR. The folder must be writable (CrystalDiskInfo writes DiskInfo.txt there).
$CdiDir     = if ($env:DISKHEALTH_CDI_DIR) { $env:DISKHEALTH_CDI_DIR } else { Join-Path $Root 'CrystalDiskInfo' }
$CdiExe     = 'DiskInfo64.exe'
foreach ($n in 'DiskInfo64.exe', 'DiskInfo64S.exe', 'DiskInfo64K.exe') { if (Test-Path (Join-Path $CdiDir $n)) { $CdiExe = $n; break } }

function Get-State {
    $h = @{}
    if (Test-Path $StateFile) {
        (Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties |
            ForEach-Object { $h[$_.Name] = $_.Value }
    }
    $h
}

function Save-State($h) {
    New-Item -ItemType Directory -Force $DataDir | Out-Null
    $h | ConvertTo-Json | Set-Content $StateFile -Encoding UTF8
}

function Esc([string]$s) { [Security.SecurityElement]::Escape($s) }

function Show-Toast {
    param([string]$Xml, [string]$Tag = 'main', [switch]$Silent, [int]$ExpireDays = 30)
    [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
    $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
    $doc.LoadXml($Xml)
    $t = New-Object Windows.UI.Notifications.ToastNotification $doc
    $t.Tag = $Tag
    $t.Group = 'diskhealth'
    $t.ExpirationTime = [DateTimeOffset]::Now.AddDays($ExpireDays)
    if ($Silent) { $t.SuppressPopup = $true }
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($AppId).Show($t)
}

function Remove-Toast([string]$Tag) {
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [Windows.UI.Notifications.ToastNotificationManager]::History.Remove($Tag, 'diskhealth', $AppId)
    } catch {}
}

function Show-SimpleToast([string]$Title, [string]$Body, [string]$Tag = 'info', [string]$Button = '', [string]$Arg = '') {
    $actions = ''
    if ($Button) { $actions = "<actions><action content=`"$(Esc $Button)`" activationType=`"protocol`" arguments=`"$Arg`"/></actions>" }
    $launch = if ($Arg) { " launch=`"$Arg`" activationType=`"protocol`"" } else { '' }
    Show-Toast -Tag $Tag -Xml @"
<toast$launch><visual><binding template="ToastGeneric"><text>$(Esc $Title)</text><text>$(Esc $Body)</text></binding></visual>$actions</toast>
"@
}
