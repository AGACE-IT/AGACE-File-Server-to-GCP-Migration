#Requires -Version 5.1
# 03-Build-Jobs.ps1 - converts the APPROVED summary_folders.csv into the robocopy job list (jobs.csv).
param(
    [string]$SummaryCsv = 'C:\AGACE-Migration\inventory\summary_folders.csv',
    [string]$OutCsv = 'C:\AGACE-Migration\jobs\jobs.csv',
    [string]$HotShare = '\\agace-gcp-fs01.agace.local\Hot$',
    [string]$ColdShare = '\\agace-gcp-fs01.agace.local\ColdStage$',
    [string]$SplitDate = '20210101',
    [string[]]$DriveOrder = @('D:', 'C:', 'W:', 'F:', 'G:'),
    [hashtable]$RootMap = @{
        'D:\Informacion' = 'D_Informacion'
        'F:\Lacie'       = 'F_Lacie'
        'G:\Seagate'     = 'G_Seagate'
        'W:\Sistemas'    = 'W_Sistemas'
    }
)
$ErrorActionPreference = 'Stop'
$rows = @(Import-Csv $SummaryCsv)
$bad = @($rows | Where-Object { $_.Tier -notin 'Hot', 'Cold', 'Split', 'Exclude' })
if ($bad.Count) { throw "$($bad.Count) rows still have Tier='Review' (or invalid). Set each to Hot, Cold, Split or Exclude before building jobs." }
if (Test-Path $OutCsv) { throw "$OutCsv already exists. Archive it first; never regenerate job IDs mid-migration." }
New-Item -ItemType Directory -Path (Split-Path $OutCsv) -Force | Out-Null

$excluded = @($rows | Where-Object Tier -eq 'Exclude')
if ($excluded.Count) { $excluded | Export-Csv (Join-Path (Split-Path $OutCsv) 'excluded_units.csv') -NoTypeInformation -Encoding UTF8 }
$jobs = New-Object System.Collections.Generic.List[object]
$id = 0
foreach ($r in $rows | Where-Object Tier -ne 'Exclude') {
    $destRoot = $RootMap[$r.Root]
    if (-not $destRoot) { throw "Root '$($r.Root)' is missing from -RootMap." }
    $src = if ($r.Unit) { "$($r.Root)\$($r.Unit)" } else { $r.Root }
    $rel = if ($r.Unit) { "$destRoot\$($r.Unit)" } else { $destRoot }
    $drivePrio = [array]::IndexOf($DriveOrder, $r.Root.Substring(0, 2).ToUpper())
    if ($drivePrio -lt 0) { $drivePrio = 99 }
    $coldFrac = [double]$r.ColdPct / 100
    $variants = @()
    if ($r.Tier -eq 'Split') {
        $variants += , @('Hot', "/MAXAGE:$SplitDate", [math]::Round([double]$r.Bytes * (1 - $coldFrac)))
        $variants += , @('Cold', "/MINAGE:$SplitDate", [math]::Round([double]$r.Bytes * $coldFrac))
    } else {
        $variants += , @($r.Tier, '', [double]$r.Bytes)
    }
    foreach ($v in $variants) {
        $id++
        $tierRank = if ($v[0] -eq 'Hot') { 1 } else { 2 }
        $share = if ($v[0] -eq 'Hot') { $HotShare } else { $ColdShare }
        $jobs.Add([pscustomobject]@{
            JobId       = 'J{0:D5}' -f $id
            Priority    = $tierRank * 100 + $drivePrio
            Tier        = $v[0]
            Source      = $src
            Destination = "$share\$rel"
            Recurse     = $r.Recurse
            AgeSwitch   = $v[1]
            Files       = $r.Files
            Bytes       = $v[2]
            Status      = 'Pending'
            LastExit    = ''
            LastRun     = ''
        })
    }
}
$jobs | Sort-Object Priority, Source | Export-Csv $OutCsv -NoTypeInformation -Encoding UTF8
$jobs | Group-Object Tier | ForEach-Object {
    [pscustomobject]@{ Tier = $_.Name; Jobs = $_.Count; TB = [math]::Round(($_.Group | Measure-Object Bytes -Sum).Sum / 1e12, 2) }
} | Format-Table -AutoSize
