# diskhealth: 協定處理器（通知按鈕點下後由 Windows 呼叫）
param([string]$Uri)
. "$PSScriptRoot\common.ps1"

$cmd = ($Uri -replace '^diskhealth:/*', '').Trim('/').ToLower()
switch ($cmd) {
    'start' {
        Remove-Toast 'prompt'
        try {
            Start-ScheduledTask -TaskPath $TaskPath -TaskName $ScanTask -ErrorAction Stop
        } catch {
            Show-SimpleToast '硬碟健檢無法啟動' "找不到排程「$TaskPath$ScanTask」，請重新執行 install.ps1。`n$($_.Exception.Message)"
        }
    }
    'postpone' {
        & "$PSScriptRoot\notify.ps1" -Silent
    }
    'open-report' {
        $st = Get-State
        $report = $st.lastReport
        if (-not $report -or -not (Test-Path $report)) {
            $report = Get-ChildItem $ReportDir -Filter '*.html' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
        }
        if ($report) { Start-Process $report } else { Start-Process $ReportDir }
    }
    'open-log' {
        Start-Process (Join-Path $DataDir 'health_check.log')
    }
}
