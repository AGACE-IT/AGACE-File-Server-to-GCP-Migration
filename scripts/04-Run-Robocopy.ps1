#Requires -Version 5.1
# 04-Run-Robocopy.ps1 - window-aware robocopy orchestrator.
#   Baseline : copies Pending/Failed/Partial/NotVerified units (updates jobs.csv)
#   Delta    : re-syncs Hot units already Done/Verified (does NOT modify jobs.csv; cold archive is static)
#   Verify   : robocopy /L on Done units; exit 0 or 2 => Verified (updates jobs.csv)
#   -Purge   : (cutover only) adds /PURGE to Delta, or previews it with Verify. Hot units without age filter only.
param(
    [Parameter(Mandatory)][ValidateSet('Baseline', 'Delta', 'Verify')][string]$Mode,
    [string]$JobsCsv = 'C:\AGACE-Migration\jobs\jobs.csv',
    [string]$LogRoot = 'C:\AGACE-Migration\logs',
    [string]$Window,
    [int]$MaxParallel = 4,
    [int]$Threads = 32,
    [hashtable]$ThreadsByDrive = @{ 'F:' = 8; 'G:' = 8 },
    [int]$GraceMinutes = 15,
    [ValidateSet('All', 'Hot', 'Cold')][string]$Tier = 'All',
    [switch]$Reverify,
    [switch]$Purge,
    [string]$HotCopy = '/COPY:DATSO',
    [string]$ControlDir = '\\agace-gcp-fs01.agace.local\ColdStage$\_control'
)
$ErrorActionPreference = 'Stop'
if ($Purge -and $Mode -eq 'Baseline') { throw '-Purge is only allowed with -Mode Delta or -Mode Verify.' }
if (-not $Window) { $Window = if ($Mode -eq 'Delta') { '2359-0400' } else { '2200-0500' } }
$common = @('/DCOPY:DAT', '/B', '/R:2', '/W:5', '/XJ', '/NP', '/NDL', '/FP', '/BYTES', "/RH:$Window", '/PF',
            '/XD', '$RECYCLE.BIN', 'System Volume Information', '$WinREAgent', 'Config.Msi', 'RECYCLER',
            '/XF', 'pagefile.sys', 'hiberfil.sys', 'swapfile.sys', 'Thumbs.db', '~$*')

function Get-WindowEnd([string]$w) {
    $s, $e = $w.Split('-')
    $now = Get-Date
    $start = $now.Date.AddHours([int]$s.Substring(0, 2)).AddMinutes([int]$s.Substring(2, 2))
    $end = $now.Date.AddHours([int]$e.Substring(0, 2)).AddMinutes([int]$e.Substring(2, 2))
    if ($end -le $start -and $now -ge $start) { $end = $end.AddDays(1) }
    $end
}
function Read-Jobs {
    for ($i = 0; $i -lt 5; $i++) { try { return @(Import-Csv $JobsCsv) } catch { Start-Sleep -Seconds 2 } }
    throw "Cannot read $JobsCsv"
}
function Save-Jobs($list) {
    $list | Export-Csv "$JobsCsv.tmp" -NoTypeInformation -Encoding UTF8
    Move-Item "$JobsCsv.tmp" $JobsCsv -Force
}
function ConvertTo-Arg([string]$a) { if ($a -match '[\s$~]') { '"' + $a + '"' } else { $a } }
function Get-Drive($j) { $j.Source.Substring(0, 2).ToUpper() }

if ($Mode -ne 'Delta') {
    $mutex = New-Object System.Threading.Mutex($false, 'Global\AGACE-Migration-JobsCsv')
    if (-not $mutex.WaitOne(0)) { throw 'Another Baseline/Verify run is active (jobs.csv is locked).' }
}
$end = Get-WindowEnd $Window
$runDir = Join-Path $LogRoot ('{0}\{1:yyyyMMdd-HHmm}' -f $Mode, (Get-Date))
New-Item -ItemType Directory -Path $runDir -Force | Out-Null
$jobs = Read-Jobs
$want = switch ($Mode) {
    'Baseline' { @('Pending', 'Failed', 'Fatal', 'Partial', 'Running', 'NotVerified') }
    'Delta'    { @('Done', 'Verified') }
    'Verify'   { if ($Reverify) { @('Done', 'Verified') } else { @('Done') } }
}
$pending = New-Object System.Collections.Generic.List[object]
$jobs | Where-Object {
    $_.Status -in $want -and ($Tier -eq 'All' -or $_.Tier -eq $Tier) -and -not ($Mode -eq 'Delta' -and $_.Tier -eq 'Cold') -and
    -not ($Purge -and ($_.Tier -ne 'Hot' -or $_.AgeSwitch))
} | Sort-Object { [int]$_.Priority }, Source | ForEach-Object { $pending.Add($_) }
Write-Host "$Mode : $($pending.Count) units selected; window ends $end"

$running = @{}
$summary = New-Object System.Collections.Generic.List[object]
while ($pending.Count -gt 0 -or $running.Count -gt 0) {
    # Launch: max one job per physical source drive (avoids seek thrash on F:/G: USB disks)
    while ($pending.Count -gt 0 -and $running.Count -lt $MaxParallel -and (Get-Date) -lt $end) {
        $busy = @($running.Values | ForEach-Object { Get-Drive $_.J })
        $j = $pending | Where-Object { $busy -notcontains (Get-Drive $_) } | Select-Object -First 1
        if (-not $j) { break }
        [void]$pending.Remove($j)
        $mt = if ($ThreadsByDrive.ContainsKey((Get-Drive $j))) { $ThreadsByDrive[(Get-Drive $j)] } else { $Threads }
        $log = Join-Path $runDir "$($j.JobId).log"
        $rc = @($j.Source, $j.Destination)
        if ($j.Recurse -eq 'True') { $rc += '/E' }
        $rc += $(if ($j.Tier -eq 'Hot') { $HotCopy } else { '/COPY:DAT' })
        if ($j.AgeSwitch) { $rc += $j.AgeSwitch }
        if ($Mode -eq 'Verify') { $rc += '/L' }
        if ($Purge) { $rc += '/PURGE' }
        $rc += $common + @("/MT:$mt", "/UNILOG:$log")
        $line = ($rc | ForEach-Object { ConvertTo-Arg $_ }) -join ' '
        $p = Start-Process -FilePath "$env:SystemRoot\System32\robocopy.exe" -ArgumentList $line -WindowStyle Hidden -PassThru
        $null = $p.Handle
        $running[$j.JobId] = @{ P = $p; J = $j; T = Get-Date }
        if ($Mode -eq 'Baseline') { $j.Status = 'Running'; $j.LastRun = (Get-Date).ToString('s'); Save-Jobs $jobs }
    }
    foreach ($id in @($running.Keys)) {
        $r = $running[$id]
        $j = $r.J
        if ($r.P.HasExited) {
            $code = $r.P.ExitCode
            if ($Mode -eq 'Verify') {
                $status = if ($code -eq 0 -or $code -eq 2) { 'Verified' } elseif ($code -lt 8) { 'NotVerified' } else { 'Failed' }
            } else {
                $status = if ($code -ge 16) { 'Fatal' } elseif ($code -ge 8) { 'Failed' } else { 'Done' }
            }
        } elseif ((Get-Date) -gt $end.AddMinutes($GraceMinutes)) {
            Stop-Process -Id $r.P.Id -Force
            $code = -1
            $status = 'Partial'
        } else { continue }
        $running.Remove($id)
        $summary.Add([pscustomobject]@{
            JobId = $id; Tier = $j.Tier; Source = $j.Source; Exit = $code; Status = $status
            Start = $r.T.ToString('s'); End = (Get-Date).ToString('s'); Log = Join-Path $runDir "$id.log"
        })
        if ($Mode -ne 'Delta') { $j.Status = $status; $j.LastExit = $code; Save-Jobs $jobs }
    }
    if ((Get-Date) -ge $end -and $pending.Count -gt 0) { $pending.Clear() }
    Start-Sleep -Seconds 15
}

$summary | Export-Csv (Join-Path $runDir 'summary.csv') -NoTypeInformation -Encoding UTF8
$bad = @($summary | Where-Object { $_.Status -in 'Failed', 'Fatal', 'NotVerified' })
$msg = "AGACE $Mode finished: $($summary.Count) units run, $($bad.Count) need attention. Logs: $runDir"
$evtId = if ($bad.Count) { 1002 } else { 1000 }
$evtType = if ($bad.Count) { 'Warning' } else { 'Information' }
try { Write-EventLog -LogName Application -Source 'AGACE-Migration' -EventId $evtId -EntryType $evtType -Message $msg } catch { }
if ($Mode -ne 'Delta' -and $ControlDir) { try { Copy-Item $JobsCsv (Join-Path $ControlDir 'jobs.csv') -Force } catch { Write-Warning "Could not publish jobs.csv to $ControlDir" } }
Write-Host $msg
