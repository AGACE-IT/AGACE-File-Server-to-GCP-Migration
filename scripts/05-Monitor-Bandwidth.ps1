#Requires -Version 5.1
# 05-Monitor-Bandwidth.ps1 - samples NIC bytes sent (language-neutral, no perf-counter names),
# raises an event if throughput < 70% of plan for 30 min, and writes a completion projection at window end.
param(
    [string]$Window = '2200-0500',
    [double]$WindowHours = 7,
    [string]$Adapter = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1).InterfaceAlias,
    [int]$IntervalSec = 60,
    [double]$PlannedMBps = 50,
    [datetime]$LastBaselineNight = '2026-12-02',
    [string]$JobsCsv = 'C:\AGACE-Migration\jobs\jobs.csv',
    [string]$OutDir = 'C:\AGACE-Migration\monitor'
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
function Write-AgaceEvent([int]$id, [string]$type, [string]$msg) {
    try { Write-EventLog -LogName Application -Source 'AGACE-Migration' -EventId $id -EntryType $type -Message $msg } catch { }
    Write-Host $msg
}
function Get-WindowEnd([string]$w) {
    $s, $e = $w.Split('-')
    $now = Get-Date
    $start = $now.Date.AddHours([int]$s.Substring(0, 2)).AddMinutes([int]$s.Substring(2, 2))
    $end = $now.Date.AddHours([int]$e.Substring(0, 2)).AddMinutes([int]$e.Substring(2, 2))
    if ($end -le $start -and $now -ge $start) { $end = $end.AddDays(1) }
    $end
}
$end = Get-WindowEnd $Window
$csv = Join-Path $OutDir ('bw_{0:yyyyMMdd}.csv' -f (Get-Date))
$t0 = Get-Date
$first = [double](Get-NetAdapterStatistics -Name $Adapter).SentBytes
$prev = $first
$cur = $first
$tPrev = $t0
$low = 0
while ((Get-Date) -lt $end) {
    Start-Sleep -Seconds $IntervalSec
    $cur = [double](Get-NetAdapterStatistics -Name $Adapter).SentBytes
    $now = Get-Date
    $mbps = ($cur - $prev) / 1e6 / [math]::Max(($now - $tPrev).TotalSeconds, 1)
    $prev = $cur
    $tPrev = $now
    if ($mbps -lt 0) { continue }
    [pscustomobject]@{ Time = $now.ToString('s'); MBytesPerSec = [math]::Round($mbps, 2); MbitPerSec = [math]::Round($mbps * 8, 1) } |
        Export-Csv $csv -Append -NoTypeInformation
    if ($mbps -lt 0.7 * $PlannedMBps) { $low++ } else { $low = 0 }
    if ($low -ge [math]::Ceiling(1800 / $IntervalSec)) {
        Write-AgaceEvent 1101 'Warning' ("Throughput {0:N1} MB/s is below 70% of plan ({1} MB/s) for 30 min. Check ISP/VPN (Section 6)." -f $mbps, $PlannedMBps)
        $low = 0
    }
}
$avg = ($cur - $first) / 1e6 / [math]::Max(((Get-Date) - $t0).TotalSeconds, 1)
$jobs = @(Import-Csv $JobsCsv)
$rem = @{}
foreach ($t in 'Hot', 'Cold') {
    $rem[$t] = [double](($jobs | Where-Object { $_.Tier -eq $t -and $_.Status -notin 'Done', 'Verified' } |
        ForEach-Object { [double]$_.Bytes } | Measure-Object -Sum).Sum)
}
$nightsLeft = ($LastBaselineNight.Date - (Get-Date).Date).Days + 1
$perNight = $avg * 1e6 * $WindowHours * 3600 * 0.9
$needAll = if ($perNight -gt 0) { ($rem.Hot + $rem.Cold) / $perNight } else { [double]::PositiveInfinity }
$needHot = if ($perNight -gt 0) { $rem.Hot / $perNight } else { [double]::PositiveInfinity }
$rag = if ($needAll -le $nightsLeft - 1) { 'GREEN' } elseif ($needHot -le $nightsLeft - 1) { 'AMBER' } else { 'RED' }
$row = [pscustomobject]@{
    Night = $t0.ToString('yyyy-MM-dd'); AvgMBps = [math]::Round($avg, 2); TBThisNight = [math]::Round(($cur - $first) / 1e12, 3)
    RemainingHotTB = [math]::Round($rem.Hot / 1e12, 3); RemainingColdTB = [math]::Round($rem.Cold / 1e12, 3)
    NightsNeededAll = [math]::Round($needAll, 1); NightsNeededHot = [math]::Round($needHot, 1); NightsLeft = $nightsLeft; Status = $rag
}
$row | Export-Csv (Join-Path $OutDir 'projection.csv') -Append -NoTypeInformation
$evt = switch ($rag) { 'GREEN' { 1200 } 'AMBER' { 1201 } default { 1202 } }
Write-AgaceEvent $evt $(if ($rag -eq 'GREEN') { 'Information' } else { 'Warning' }) ($row | Format-List | Out-String)
