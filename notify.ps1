# 跳出「每月硬碟健檢」通知（開始掃描 / 延後）
# 由排程「每月提醒」觸發（每月 1 號 + 每次登入補檢查）；-Silent 用於「延後」：不跳出、直接放進通知中心
param([switch]$Silent, [switch]$Force)
. "$PSScriptRoot\common.ps1"

$month = Get-Date -Format 'yyyy-MM'
$st = Get-State

if (-not $Silent -and -not $Force) {
    if ($st.lastScanMonth -eq $month) { exit }   # 本月已健檢
    if ($st.lastPromptDate -and $st.lastPromptDate.StartsWith($month) -and
        ((Get-Date) - [datetime]$st.lastPromptDate).TotalDays -lt 7) { exit }   # 本月 7 天內已詢問過，通知還躺在通知中心
}
if (-not $Silent) {
    $st.lastPromptDate = Get-Date -Format 'yyyy-MM-dd HH:mm'
    Save-State $st
}

$diskCount = @(Get-PhysicalDisk).Count
$last = if ($st.lastScanDate) { "上次健檢：$($st.lastScanDate)" } else { '尚無健檢紀錄' }

Show-Toast -Tag 'prompt' -Silent:$Silent -Xml @"
<toast scenario="reminder" launch="diskhealth:postpone" activationType="protocol">
  <visual><binding template="ToastGeneric">
    <text>每月硬碟健檢</text>
    <text>要現在檢查全部 $diskCount 顆硬碟嗎？（SMART + 檔案系統線上掃描，約 20–40 分鐘，可照常使用電腦）</text>
    <text placement="attribution">$(Esc $last)</text>
  </binding></visual>
  <actions>
    <action content="開始掃描" activationType="protocol" arguments="diskhealth:start"/>
    <action content="延後" activationType="protocol" arguments="diskhealth:postpone"/>
  </actions>
</toast>
"@
