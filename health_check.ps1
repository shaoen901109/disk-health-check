# 硬碟健檢主程式（需系統管理員權限；由排程「執行掃描」以最高權限執行）
#   1. CrystalDiskInfo /CopyExit 讀全部硬碟 SMART
#   2. Windows 儲存可靠性計數器
#   3. 每個 NTFS 磁碟區線上掃描（Repair-Volume -Scan，唯讀、不鎖碟）
#   4. 系統事件記錄中的磁碟／檔案系統錯誤
#   5. 與上次結果比對，輸出 HTML 報告並跳通知
# 重建報告用：-CdiFile 用存下來的 DiskInfo 文字檔，-VolumesFrom 沿用某次 scan_*.json 的磁碟區掃描結果
param([switch]$NoVolumeScan, [string]$CdiFile, [string]$VolumesFrom)
. "$PSScriptRoot\common.ps1"
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $DataDir, $ReportDir | Out-Null
$now   = Get-Date
$stamp = $now.ToString('yyyy-MM-dd_HHmm')
Start-Transcript -Path (Join-Path $DataDir 'health_check.log') -Append | Out-Null

function Enc($s) { [Net.WebUtility]::HtmlEncode([string]$s) }
function Num($s) { if ("$s" -match '([\d,]+(\.\d+)?)') { [double]($matches[1] -replace ',', '') } else { $null } }
function Fmt($n, $d = 0) { if ($null -eq $n) { '—' } else { ([double]$n).ToString("N$d") } }
$LevelRank = @{ good = 0; info = 0; unknown = 1; warn = 2; bad = 3 }
$LevelText = @{ good = '良好'; info = '良好'; unknown = '未知'; warn = '注意'; bad = '危險' }
function Worse($a, $b) { if ($LevelRank[$b] -gt $LevelRank[$a]) { $b } else { $a } }

# ---------------------------------------------------------------- CrystalDiskInfo
function Invoke-Cdi {
    if ($CdiFile) { return [IO.File]::ReadAllText($CdiFile) }
    $exe = Join-Path $CdiDir $CdiExe
    if (-not (Test-Path $exe)) { throw "找不到 CrystalDiskInfo：$exe" }
    $out = Join-Path $CdiDir 'DiskInfo.txt'
    $before = if (Test-Path $out) { (Get-Item $out).LastWriteTime } else { [datetime]::MinValue }
    $p = Start-Process $exe -ArgumentList '/CopyExit' -WorkingDirectory $CdiDir -PassThru
    if (-not $p.WaitForExit(300000)) { $p.Kill(); throw 'CrystalDiskInfo 執行逾時（5 分鐘）' }
    if (-not (Test-Path $out) -or (Get-Item $out).LastWriteTime -le $before) { throw 'CrystalDiskInfo 沒有產生新的 DiskInfo.txt' }
    Copy-Item $out (Join-Path $DataDir "DiskInfo_$stamp.txt") -Force
    $b = [IO.File]::ReadAllBytes($out)
    if ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) { return [Text.Encoding]::Unicode.GetString($b, 2, $b.Length - 2) }
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { return [Text.Encoding]::UTF8.GetString($b, 3, $b.Length - 3) }
    [Text.Encoding]::UTF8.GetString($b)
}

function ConvertFrom-Cdi([string]$text) {
    $disks = New-Object System.Collections.ArrayList
    $cur = $null; $mode = ''
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^\s*\((\d+)\)\s+([^:]+?)\s*$') {
            $cur = [ordered]@{ Index = [int]$matches[1]; Title = $matches[2]; Info = [ordered]@{}; Attr = New-Object System.Collections.ArrayList; Nvme = $false }
            [void]$disks.Add($cur); $mode = 'kv'; continue
        }
        if (-not $cur) { continue }
        if ($line -match '^-{20,}\s*$') { continue }   # 分隔線
        if ($line -match '^--\s*S\.M\.A\.R\.T\.') { $mode = 'smart'; continue }
        if ($line -match '^--') { $mode = 'other'; continue }
        if ($mode -eq 'kv' -and $line -match '^\s*([^:]+?)\s+:\s?(.*)$') { $cur.Info[$matches[1].Trim()] = $matches[2].Trim(); continue }
        if ($mode -eq 'smart') {
            if ($line -match '^([0-9A-F]{2})\s+(\d+|_+\d*)\s+(\d+|_+\d*)\s+(\d+|_+\d*)\s+([0-9A-F]{12})\s+(.*)$') {
                [void]$cur.Attr.Add([ordered]@{ Id = $matches[1]; Cur = $matches[2]; Wor = $matches[3]; Thr = $matches[4]; Raw = $matches[5]; Name = $matches[6].Trim() })
            } elseif ($line -match '^([0-9A-F]{2})\s+([0-9A-F]{12,16})\s+(.*)$') {
                $cur.Nvme = $true
                [void]$cur.Attr.Add([ordered]@{ Id = $matches[1]; Cur = ''; Wor = ''; Thr = ''; Raw = $matches[2]; Name = $matches[3].Trim() })
            }
        }
    }
    $disks
}

function Info($d, [string[]]$keys) { foreach ($k in $keys) { if ($d.Info.Contains($k) -and $d.Info[$k]) { return $d.Info[$k] } }; $null }

# ATA 屬性取低 4 bytes（部分廠商高位元塞別的資料）；NVMe 取整個值
function AttrVal($d, $id) {
    $a = $d.Attr | Where-Object { $_.Id -eq $id } | Select-Object -First 1
    if (-not $a) { return $null }
    $hex = if ($d.Nvme) { $a.Raw } else { $a.Raw.Substring($a.Raw.Length - 8) }
    [double][Convert]::ToUInt64($hex, 16)
}

$AtaKeys = [ordered]@{
    '05' = @{ n = '重新配置磁區數 (Reallocated)';  lvl = 'warn' }
    'C5' = @{ n = '待重新配置磁區 (Pending)';      lvl = 'warn' }
    'C6' = @{ n = '無法修正磁區 (Uncorrectable)';  lvl = 'warn' }
    'BB' = @{ n = '回報無法修正錯誤';              lvl = 'warn' }
    '0A' = @{ n = '主軸馬達重試 (Spin Retry)';     lvl = 'warn' }
    'C7' = @{ n = 'UltraDMA CRC 錯誤（多為 SATA 線／接頭）'; lvl = 'info' }
}
$NvmeKeys = [ordered]@{
    '01' = @{ n = '嚴重警告旗標 (Critical Warning)';        lvl = 'bad' }
    '0E' = @{ n = '媒體與資料完整性錯誤 (Media Errors)';     lvl = 'warn' }
    '0F' = @{ n = '錯誤記錄項目數';                          lvl = 'info' }
    '0D' = @{ n = '不安全關機次數';                          lvl = 'info' }
}

# ---------------------------------------------------------------- 主流程
try {
    Remove-Toast 'prompt'
    Show-SimpleToast '硬碟健檢進行中…' '正在讀取 SMART 並線上掃描各磁碟區，完成後會再通知你。' -Tag 'progress'

    Write-Host "[$(Get-Date -f T)] CrystalDiskInfo"
    $cdi = ConvertFrom-Cdi (Invoke-Cdi)
    if ($cdi.Count -eq 0) { throw 'DiskInfo.txt 解析不到任何硬碟' }

    # 上次結果（同序號比對）
    $prev = $null
    $prevFile = Get-ChildItem $DataDir -Filter 'scan_*.json' | Sort-Object Name -Descending | Select-Object -First 1
    if ($prevFile) { $prev = Get-Content $prevFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json }

    # Windows 端資訊
    $pdisks = @(Get-PhysicalDisk)
    $letterMap = @{}
    Get-Partition -ErrorAction SilentlyContinue | Where-Object DriveLetter | ForEach-Object {
        $letterMap["$($_.DiskNumber)"] = (@($letterMap["$($_.DiskNumber)"]) + "$($_.DriveLetter):" | Where-Object { $_ }) -join ' '
    }
    function Norm($s) { ("$s" -replace '[^A-Za-z0-9]', '').ToUpper() }

    $disks = foreach ($d in $cdi) {
        $model  = Info $d 'Model'
        if (-not $model) { $model = $d.Title }
        $serial = Info $d 'Serial Number'
        $pd = $pdisks | Where-Object { $serial -and (Norm $_.SerialNumber) -and ((Norm $_.SerialNumber).Contains((Norm $serial)) -or (Norm $serial).Contains((Norm $_.SerialNumber))) } | Select-Object -First 1
        if (-not $pd) { $pd = $pdisks | Where-Object { (Norm $_.FriendlyName) -eq (Norm $model) } | Select-Object -First 1 }
        $rel = if ($pd) { try { $pd | Get-StorageReliabilityCounter -ErrorAction Stop } catch { $null } }
        $num = if ($pd) { "$($pd.DeviceId)" } else { $null }

        $healthTxt = "$(Info $d 'Health Status')"
        $healthPct = if ($healthTxt -match '(\d+)\s*%') { [int]$matches[1] } else { $null }
        $level = if ($healthTxt -match 'Good|良好|正常') { 'good' } elseif ($healthTxt -match 'Caution|警告|注意') { 'warn' } elseif ($healthTxt -match 'Bad|不良|危險') { 'bad' } else { 'unknown' }
        $findings = New-Object System.Collections.ArrayList
        if ($level -ne 'good') { [void]$findings.Add(@{ lvl = $level; t = "CrystalDiskInfo 判定：$healthTxt" }) }
        if ($pd -and $pd.HealthStatus -ne 'Healthy') { $level = Worse $level 'warn'; [void]$findings.Add(@{ lvl = 'warn'; t = "Windows 回報健康狀態：$($pd.HealthStatus)" }) }

        $pDisk = if ($prev) { $prev.disks | Where-Object { $_.serial -eq $serial } | Select-Object -First 1 } else { $null }
        function PrevKey($id) { if ($pDisk -and $pDisk.keys) { $k = $pDisk.keys | Where-Object { $_.id -eq $id } | Select-Object -First 1; if ($k) { [double]$k.v } } }

        $keys = New-Object System.Collections.ArrayList
        $defs = if ($d.Nvme) { $NvmeKeys } else { $AtaKeys }
        foreach ($id in $defs.Keys) {
            $v = AttrVal $d $id
            if ($null -eq $v) { continue }
            $pv = PrevKey $id
            $delta = if ($null -ne $pv) { $v - $pv } else { $null }
            [void]$keys.Add([ordered]@{ id = $id; n = $defs[$id].n; v = $v; delta = $delta })
            $lvl = $defs[$id].lvl
            if ($id -eq '0D' -or $id -eq '0F') { continue }   # 只顯示，不判定
            if ($v -gt 0) {
                if ($lvl -eq 'info' -and $delta -gt 0) { $lvl = 'warn' }
                $extra = if ($delta -gt 0) { "（比上次 +$(Fmt $delta)）" } elseif ($delta -eq 0) { '（與上次相同，未惡化）' } else { '' }
                [void]$findings.Add(@{ lvl = $lvl; t = "$($defs[$id].n) = $(Fmt $v)$extra" })
                if ($lvl -ne 'info') { $level = Worse $level $lvl }
            }
        }
        if ($d.Nvme) {
            $spare = AttrVal $d '03'; $spareThr = AttrVal $d '04'; $used = AttrVal $d '05'
            if ($null -ne $spare -and $null -ne $spareThr -and $spare -le $spareThr) { $level = Worse $level 'bad'; [void]$findings.Add(@{ lvl = 'bad'; t = "備用區塊 $spare% 已低於門檻 $spareThr%" }) }
            if ($null -ne $used -and $used -ge 80) { $l = if ($used -ge 100) { 'bad' } else { 'warn' }; $level = Worse $level $l; [void]$findings.Add(@{ lvl = $l; t = "已用壽命 $used%（廠商標稱寫入量）" }) }
        }

        $temp = Num (Info $d 'Temperature')
        $tLimit = if ($d.Nvme) { 70 } else { 50 }
        if ($temp -ge $tLimit) { $level = Worse $level 'warn'; [void]$findings.Add(@{ lvl = 'warn'; t = "溫度偏高 $temp °C（建議 < $tLimit °C）" }) }
        if ($rel -and ($rel.ReadErrorsUncorrected -gt 0 -or $rel.WriteErrorsUncorrected -gt 0)) {
            $level = Worse $level 'warn'
            [void]$findings.Add(@{ lvl = 'warn'; t = "Windows 計數：無法修正的讀取錯誤 $($rel.ReadErrorsUncorrected)、寫入錯誤 $($rel.WriteErrorsUncorrected)" })
        }

        $rot = "$(Info $d 'Rotation Rate')"
        $type = if ($d.Nvme) { 'NVMe SSD' } elseif ($rot -match 'RPM') { "HDD $rot" } elseif ($pd -and $pd.MediaType -eq 'HDD') { 'HDD' } else { 'SATA SSD' }
        $poh  = Num (Info $d 'Power On Hours')
        if ($null -eq $poh) { $poh = if ($d.Nvme) { AttrVal $d '0C' } else { AttrVal $d '09' } }
        $writes = Num (Info $d 'Host Writes')

        [ordered]@{
            model = $model; serial = $serial; firmware = Info $d 'Firmware'; type = $type
            size = "$(Info $d 'Disk Size')" -replace '\s*\(.*\)$', ''; iface = Info $d 'Interface'; transfer = Info $d 'Transfer Mode'
            letters = if ($num -and $letterMap[$num]) { $letterMap[$num] } else { Info $d 'Drive Letter' }
            diskNumber = $num; health = $healthTxt; healthPct = $healthPct; level = $level
            temp = $temp; poh = $poh; powerCount = Num (Info $d 'Power On Count'); writes = $writes; reads = Num (Info $d 'Host Reads')
            prevPoh = if ($pDisk) { $pDisk.poh } else { $null }; prevWrites = if ($pDisk) { $pDisk.writes } else { $null }
            prevHealthPct = if ($pDisk) { $pDisk.healthPct } else { $null }
            keys = $keys; findings = $findings; attr = $d.Attr; nvme = $d.Nvme
            used = if ($d.Nvme) { AttrVal $d '05' } else { $null }; spare = if ($d.Nvme) { AttrVal $d '03' } else { $null }
            rel = if ($rel) { [ordered]@{ ReadErrorsTotal = $rel.ReadErrorsTotal; ReadErrorsUncorrected = $rel.ReadErrorsUncorrected; WriteErrorsTotal = $rel.WriteErrorsTotal; WriteErrorsUncorrected = $rel.WriteErrorsUncorrected; Wear = $rel.Wear; StartStopCycleCount = $rel.StartStopCycleCount } } else { $null }
        }
    }
    $disks = @($disks)

    # ------------------------------------------------------------ 磁碟區掃描
    $reuse = if ($VolumesFrom) { @((Get-Content $VolumesFrom -Raw -Encoding UTF8 | ConvertFrom-Json).volumes) } else { @() }
    $volumes = foreach ($v in (Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.FileSystem -in 'NTFS', 'ReFS' } | Sort-Object DriveLetter)) {
        $L = "$($v.DriveLetter)"
        $freePct = if ($v.Size) { [math]::Round($v.SizeRemaining / $v.Size * 100, 1) } else { 0 }
        $res = '略過'; $lvl = 'info'; $secs = 0
        $old = $reuse | Where-Object { $_.letter -eq $L } | Select-Object -First 1
        if ($old) { $res = $old.scan; $lvl = $old.level; $secs = $old.seconds }
        elseif (-not $NoVolumeScan) {
            Write-Host "[$(Get-Date -f T)] Repair-Volume -Scan $L`:"
            $t0 = Get-Date
            try {
                $r = "$(Repair-Volume -DriveLetter $L -Scan -ErrorAction Stop)"
                $res = if ($r -eq 'NoErrorsFound') { '沒有發現錯誤' } else { "發現問題：$r（建議執行 chkdsk $L`: /spotfix）" }
                $lvl = if ($r -eq 'NoErrorsFound') { 'good' } else { 'warn' }
            } catch { $res = "掃描失敗：$($_.Exception.Message)"; $lvl = 'unknown' }
            $secs = [int]((Get-Date) - $t0).TotalSeconds
        }
        $part = Get-Partition -DriveLetter $L -ErrorAction SilentlyContinue
        [ordered]@{
            letter = $L; label = $v.FileSystemLabel; fs = $v.FileSystem; health = "$($v.HealthStatus)"
            sizeGB = [math]::Round($v.Size / 1GB); freeGB = [math]::Round($v.SizeRemaining / 1GB); freePct = $freePct
            disk = if ($part) { "$($part.DiskNumber)" } else { '' }
            scan = $res; level = $lvl; seconds = $secs
        }
    }
    $volumes = @($volumes)

    # ------------------------------------------------------------ 事件記錄
    $since = if ($prev) { [datetime]$prev.time } else { $now.AddDays(-90) }
    $evRaw = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2, 3; StartTime = $since
            ProviderName = 'disk', 'Ntfs', 'Microsoft-Windows-Ntfs', 'stornvme', 'storahci', 'iaStorAC', 'iaStorA', 'volmgr', 'partmgr', 'Microsoft-Windows-StorPort' } -ErrorAction SilentlyContinue)
    $events = @($evRaw | Group-Object ProviderName, Id | ForEach-Object {
            $e = $_.Group | Sort-Object TimeCreated
            $msg = "$($e[-1].Message)" -replace '\s+', ' '
            [ordered]@{
                provider = $e[0].ProviderName; id = $e[0].Id; level = "$($e[0].LevelDisplayName)"; count = $_.Count
                first = $e[0].TimeCreated.ToString('yyyy-MM-dd HH:mm'); last = $e[-1].TimeCreated.ToString('yyyy-MM-dd HH:mm')
                disk = if ($msg -match 'Harddisk(\d+)') { $matches[1] } else { '' }
                msg = if ($msg.Length -gt 260) { $msg.Substring(0, 260) + '…' } else { $msg }
            }
        } | Sort-Object { $_.count } -Descending)
    # 壞軌類事件（disk 7 / disk 11 / disk 51 / disk 153 / Ntfs 55 / 98）提高嚴重度
    foreach ($e in $events) {
        $serious = ($e.provider -eq 'disk' -and $e.id -in 7, 11, 51, 153) -or ($e.provider -match 'Ntfs' -and $e.id -in 55, 98, 137)
        $e.serious = $serious
        if ($serious -and $e.disk) {
            $dk = $disks | Where-Object { $_.diskNumber -eq $e.disk } | Select-Object -First 1
            if ($dk) { $dk.level = Worse $dk.level 'warn'; [void]$dk.findings.Add(@{ lvl = 'warn'; t = "系統事件 $($e.provider) #$($e.id) 出現 $($e.count) 次（最後 $($e.last)）" }) }
        }
    }

    # ------------------------------------------------------------ 結果彙整
    foreach ($v in $volumes) {
        if ($v.freePct -lt 10) {
            $dk = $disks | Where-Object { $_.diskNumber -eq $v.disk } | Select-Object -First 1
            if ($dk) { [void]$dk.findings.Add(@{ lvl = 'info'; t = "$($v.letter): 剩餘空間只有 $($v.freePct)%（$($v.freeGB) GB）" }) }
        }
        if ($v.level -eq 'warn') {
            $dk = $disks | Where-Object { $_.diskNumber -eq $v.disk } | Select-Object -First 1
            if ($dk) { $dk.level = Worse $dk.level 'warn'; [void]$dk.findings.Add(@{ lvl = 'warn'; t = "$($v.letter): 檔案系統掃描 $($v.scan)" }) }
        }
    }
    $overall = 'good'; foreach ($d in $disks) { $overall = Worse $overall $d.level }
    $nWarn = @($disks | Where-Object { $_.level -eq 'warn' }).Count
    $nBad  = @($disks | Where-Object { $_.level -eq 'bad' }).Count

    $result = [ordered]@{ time = $now.ToString('s'); disks = $disks; volumes = $volumes; events = $events; overall = $overall; since = $since.ToString('yyyy-MM-dd') }
    $result | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $DataDir "scan_$stamp.json") -Encoding UTF8

    # ------------------------------------------------------------ HTML 報告
    $badge = { param($l) "<span class=`"pill $l`">$($LevelText[$l])</span>" }
    $sb = New-Object Text.StringBuilder
    foreach ($d in $disks) {
        $hp = if ($null -ne $d.healthPct) { "$($d.healthPct)%" } else { '' }
        $hpDelta = if ($null -ne $d.healthPct -and $null -ne $d.prevHealthPct -and $d.healthPct -ne $d.prevHealthPct) { " <small>(上次 $($d.prevHealthPct)%)</small>" } else { '' }
        $pohTxt = if ($null -ne $d.poh) { "$(Fmt $d.poh) 小時 <small>≈ $(Fmt ($d.poh / 8760) 1) 年</small>" } else { '—' }
        $pohDelta = if ($null -ne $d.poh -and $null -ne $d.prevPoh) { "<small>（距上次 +$(Fmt ($d.poh - $d.prevPoh)) 小時）</small>" } else { '' }
        $rows = New-Object Text.StringBuilder
        [void]$rows.Append("<tr><th>健康度</th><td>$(Enc $d.health)$hpDelta</td></tr>")
        [void]$rows.Append("<tr><th>溫度</th><td>$(if ($null -ne $d.temp) { "$($d.temp) °C" } else { '—' })</td></tr>")
        [void]$rows.Append("<tr><th>通電時間</th><td>$pohTxt $pohDelta</td></tr>")
        if ($null -ne $d.powerCount) { [void]$rows.Append("<tr><th>開機次數</th><td>$(Fmt $d.powerCount)</td></tr>") }
        if ($null -ne $d.writes) {
            $wd = if ($null -ne $d.prevWrites) { " <small>（距上次 +$(Fmt ($d.writes - $d.prevWrites)) GB）</small>" } else { '' }
            [void]$rows.Append("<tr><th>累計寫入</th><td>$(Fmt $d.writes) GB$wd</td></tr>")
        }
        if ($null -ne $d.used) {
            $yrs = if ($d.used -gt 0 -and $d.poh) { $d.poh * (100 - $d.used) / $d.used / 8760 } else { $null }
            $life = if ($null -eq $yrs) { '' } elseif ($yrs -gt 20) { ' <small>依目前速度估計還可用 &gt; 20 年</small>' } else { " <small>依目前速度估計還可用約 $(Fmt $yrs 1) 年</small>" }
            [void]$rows.Append("<tr><th>已用壽命 / 可用備用區</th><td>$($d.used)% / $($d.spare)%$life</td></tr>")
        }
        if ($d.rel -and ($null -ne $d.rel.ReadErrorsTotal -or $null -ne $d.rel.WriteErrorsTotal) -and
            ($d.rel.ReadErrorsTotal + $d.rel.WriteErrorsTotal + $d.rel.ReadErrorsUncorrected + $d.rel.WriteErrorsUncorrected) -gt 0) {
            [void]$rows.Append("<tr><th>Windows 讀寫錯誤計數</th><td>讀 $(Fmt $d.rel.ReadErrorsTotal)（未修正 $(Fmt $d.rel.ReadErrorsUncorrected)）· 寫 $(Fmt $d.rel.WriteErrorsTotal)（未修正 $(Fmt $d.rel.WriteErrorsUncorrected)）</td></tr>")
        }
        foreach ($k in $d.keys) {
            $cls = if ($k.v -gt 0 -and $k.id -notin '0D', '0F') { ' class="hot"' } else { '' }
            $dl = if ($null -ne $k.delta -and $k.delta -ne 0) { " <small>(+$(Fmt $k.delta))</small>" } else { '' }
            [void]$rows.Append("<tr$cls><th>$(Enc $k.n)</th><td>$(Fmt $k.v)$dl</td></tr>")
        }
        $fl = if ($d.findings.Count) { '<ul class="find">' + (($d.findings | ForEach-Object { "<li class=`"$($_.lvl)`">$(Enc $_.t)</li>" }) -join '') + '</ul>' } else { '<p class="ok">沒有發現異常。</p>' }
        $attrRows = ($d.attr | ForEach-Object {
                if ($d.nvme) { "<tr><td>$($_.Id)</td><td class=`"mono`">$($_.Raw)</td><td>$(Fmt ([Convert]::ToUInt64($_.Raw,16)))</td><td>$(Enc $_.Name)</td></tr>" }
                else { "<tr><td>$($_.Id)</td><td>$($_.Cur)</td><td>$($_.Wor)</td><td>$($_.Thr)</td><td class=`"mono`">$($_.Raw)</td><td>$(Enc $_.Name)</td></tr>" }
            }) -join ''
        $attrHead = if ($d.nvme) { '<tr><th>ID</th><th>原始值</th><th>十進位</th><th>項目</th></tr>' } else { '<tr><th>ID</th><th>目前</th><th>最差</th><th>門檻</th><th>原始值</th><th>項目</th></tr>' }
        [void]$sb.Append(@"
<section class="card $($d.level)">
  <header><div><h3>$(Enc $d.model)</h3><p class="sub">$(Enc $d.type) · $(Enc $d.size) · <b>$(Enc $d.letters)</b> · 磁碟 $(Enc $d.diskNumber)</p></div>
  <div class="hp">$(& $badge $d.level)<span class="big">$hp</span></div></header>
  <table class="kv">$rows</table>
  $fl
  <details><summary>完整 S.M.A.R.T. 屬性（$($d.attr.Count) 項）· 序號 $(Enc $d.serial) · 韌體 $(Enc $d.firmware) · $(Enc $d.transfer)</summary>
  <div class="scroll"><table class="grid">$attrHead$attrRows</table></div></details>
</section>
"@)
    }
    $volRows = ($volumes | ForEach-Object {
            $bar = [math]::Max(0, [math]::Min(100, 100 - $_.freePct))
            $barCls = if ($_.freePct -lt 10) { 'bar low' } else { 'bar' }
            "<tr><td><b>$($_.letter):</b> $(Enc $_.label)</td><td>$($_.fs)</td><td>$(Fmt $_.sizeGB) GB</td><td><div class=`"$barCls`"><i style=`"width:$bar%`"></i></div>$(Fmt $_.freeGB) GB 可用（$($_.freePct)%）</td><td>$(& $badge $_.level) $(Enc $_.scan)</td><td>$($_.seconds) 秒</td></tr>"
        }) -join ''
    $evRows = if ($events.Count) {
        ($events | ForEach-Object {
                $c = if ($_.serious) { ' class="hot"' } else { '' }
                "<tr$c><td>$(Enc $_.provider) #$($_.id)</td><td>$(Enc $_.level)</td><td>$($_.count)</td><td>$($_.first)<br>$($_.last)</td><td>$(if ($_.disk) { $dn = $_.disk; $dk = $disks | Where-Object { $_.diskNumber -eq $dn } | Select-Object -First 1; if ($dk) { "磁碟 $dn<br><small>$(Enc $dk.model) $($dk.letters)</small>" } else { "磁碟 $dn<br><small>目前未連接（外接硬碟？）</small>" } })</td><td class=`"msg`">$(Enc $_.msg)</td></tr>"
            }) -join ''
    } else { '<tr><td colspan="6" class="ok">這段期間沒有任何磁碟或檔案系統的警告／錯誤事件。</td></tr>' }
    $headline = switch ($overall) {
        'good' { "全部 $($disks.Count) 顆硬碟狀況良好" }
        'warn' { "$nWarn 顆硬碟需要注意" }
        'bad' { "$nBad 顆硬碟狀況危險，請儘快備份" }
        default { '部分硬碟狀態無法判定' }
    }
    $prevTxt = if ($prev) { "與上次健檢（$(([datetime]$prev.time).ToString('yyyy-MM-dd'))）比較" } else { '這是第一次健檢，下次起會顯示與上次的差異' }

    $html = @"
<!doctype html><html lang="zh-Hant"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>硬碟健檢報告 $($now.ToString('yyyy-MM-dd'))</title>
<style>
:root{--bg:#f5f6f8;--fg:#1d2330;--mut:#667085;--card:#fff;--line:#e3e6ec;--good:#1f9d55;--warn:#d98a00;--bad:#d93636;--unk:#8a94a6;--hot:#fff4e0}
@media (prefers-color-scheme:dark){:root{--bg:#14171d;--fg:#e6e8ec;--mut:#98a2b3;--card:#1d2129;--line:#2d333e;--hot:#3a2e17}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.55 "Segoe UI","Microsoft JhengHei UI",sans-serif}
main{max-width:1180px;margin:0 auto;padding:24px 16px 60px}
h1{font-size:24px;margin:0 0 4px}h2{font-size:18px;margin:36px 0 12px}h3{margin:0;font-size:17px}
.sub,small{color:var(--mut)}.banner{border-radius:12px;padding:18px 20px;margin:18px 0;color:#fff;font-size:20px;font-weight:600}
.banner.good,.banner.info{background:var(--good)}.banner.warn{background:var(--warn)}.banner.bad{background:var(--bad)}.banner.unknown{background:var(--unk)}
.banner small{display:block;color:#ffffffcc;font-size:13px;font-weight:400;margin-top:4px}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,520px),1fr));gap:16px}
.card{background:var(--card);border:1px solid var(--line);border-left:6px solid var(--good);border-radius:10px;padding:16px 18px}
.card.warn{border-left-color:var(--warn)}.card.bad{border-left-color:var(--bad)}.card.unknown{border-left-color:var(--unk)}
.card header{display:flex;justify-content:space-between;gap:12px;align-items:flex-start}.card .sub{margin:2px 0 10px;font-size:13px}
.hp{text-align:right;white-space:nowrap}.big{display:block;font-size:26px;font-weight:700;margin-top:4px}
.pill{display:inline-block;padding:1px 10px;border-radius:99px;font-size:13px;color:#fff;background:var(--good)}
.pill.warn{background:var(--warn)}.pill.bad{background:var(--bad)}.pill.unknown{background:var(--unk)}
table{border-collapse:collapse;width:100%}.kv th{text-align:left;font-weight:500;color:var(--mut);width:46%;padding:3px 8px 3px 0}.kv td{padding:3px 0}
tr.hot{background:var(--hot)}.find{margin:10px 0 6px;padding-left:20px}.find li.warn{color:var(--warn)}.find li.bad{color:var(--bad);font-weight:600}.find li.info{color:var(--mut)}
.ok{color:var(--good);margin:10px 0 6px}details{margin-top:8px;font-size:13px}summary{cursor:pointer;color:var(--mut)}
.scroll{overflow-x:auto}.grid th,.grid td{border-bottom:1px solid var(--line);padding:4px 8px;text-align:left;font-size:13px;vertical-align:top}
.mono{font-family:Consolas,monospace}.box{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:6px 12px;overflow-x:auto}
.bar{height:6px;background:var(--line);border-radius:3px;margin:4px 0 2px;min-width:120px}.bar i{display:block;height:100%;background:#4f7cff;border-radius:3px}.bar.low i{background:var(--bad)}
.msg{min-width:320px;color:var(--mut)}footer{margin-top:40px;font-size:13px;color:var(--mut)}
</style></head><body><main>
<h1>硬碟健檢報告</h1><div class="sub">$($now.ToString('yyyy-MM-dd HH:mm')) · $(Enc $env:COMPUTERNAME) · $prevTxt</div>
<div class="banner $overall">$headline<small>判定依據：SMART（CrystalDiskInfo）、Windows 可靠性計數器、檔案系統線上掃描、系統事件記錄</small></div>
<h2>實體硬碟</h2><div class="cards">$sb</div>
<h2>磁碟區（檔案系統線上掃描）</h2>
<div class="box"><table class="grid"><tr><th>磁碟區</th><th>格式</th><th>容量</th><th>使用量</th><th>掃描結果</th><th>耗時</th></tr>$volRows</table></div>
<h2>系統事件記錄（$($since.ToString('yyyy-MM-dd')) 起的磁碟／檔案系統警告與錯誤）</h2>
<div class="box"><table class="grid"><tr><th>來源</th><th>等級</th><th>次數</th><th>首次／最後</th><th>對象</th><th>訊息（最後一筆）</th></tr>$evRows</table></div>
<footer>
<p><b>怎麼看：</b>HDD 最關鍵是「重新配置／待重新配置／無法修正磁區」，只要不是 0 就代表出現壞軌，數字若每月持續增加就該換碟；CRC 錯誤通常是 SATA 線或接頭問題。SSD 看健康度%、已用壽命、媒體錯誤與備用區塊。標成橘色的事件（disk #7、#51、#153、Ntfs #55、#98）代表讀寫曾經失敗。</p>
<p>原始資料：$(Enc (Join-Path $DataDir "DiskInfo_$stamp.txt")) · $(Enc (Join-Path $DataDir "scan_$stamp.json"))</p>
</footer></main></body></html>
"@
    $reportPath = Join-Path $ReportDir "硬碟健檢_$stamp.html"
    [IO.File]::WriteAllText($reportPath, $html, (New-Object Text.UTF8Encoding $true))

    $st = Get-State
    $st.lastScanMonth = $now.ToString('yyyy-MM')
    $st.lastScanDate  = $now.ToString('yyyy-MM-dd HH:mm')
    $st.lastReport    = $reportPath
    $st.lastOverall   = $overall
    Save-State $st

    Remove-Toast 'progress'
    $lines = ($disks | ForEach-Object { "$($_.letters) $($LevelText[$_.level])$(if ($null -ne $_.healthPct) { " $($_.healthPct)%" })" }) -join '、'
    Show-SimpleToast "硬碟健檢完成：$headline" $lines -Tag 'done' -Button '開啟報告' -Arg 'diskhealth:open-report'
    Write-Host "[$(Get-Date -f T)] 完成：$reportPath"
}
catch {
    Write-Host "錯誤：$($_.Exception.Message)`n$($_.ScriptStackTrace)"
    Remove-Toast 'progress'
    Show-SimpleToast '硬碟健檢失敗' $_.Exception.Message -Tag 'done' -Button '查看記錄' -Arg 'diskhealth:open-log'
    exit 1
}
finally { Stop-Transcript | Out-Null }
