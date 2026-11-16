#Requires -Version 5.1
# 01-Inventory.ps1 - READ-ONLY inventory of the source roots.
# Output: summary_folders.csv (one row per migration unit, with Hot/Cold/Review tier)
#         files_<root>.tsv (per-file list, only for -FileListRoots; used by 02-Find-Duplicates.ps1)
param(
    [string[]]$Roots = @('D:\Informacion', 'F:\Lacie', 'G:\Seagate', 'W:\Sistemas'),
    [hashtable]$UnitDepth = @{ 'D:\Informacion' = 1; 'F:\Lacie' = 1; 'G:\Seagate' = 2; 'W:\Sistemas' = 2 },
    [string[]]$FileListRoots = @('G:\Seagate', 'W:\Sistemas'),
    [datetime]$ColdCutoff = '2021-01-01',
    [int]$ReviewColdPct = 80,
    [double]$ReviewMinGB = 50,
    [string]$OutDir = 'C:\AGACE-Migration\inventory',
    [string[]]$ExcludeDirs = @('$RECYCLE.BIN', 'System Volume Information', '$WinREAgent', 'Config.Msi', 'RECYCLER', 'RECYCLED')
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$cutTicks = $ColdCutoff.ToUniversalTime().Ticks
$futureTicks = (Get-Date).ToUniversalTime().AddDays(1).Ticks
$utf8 = New-Object System.Text.UTF8Encoding($false)
$errLog = New-Object System.IO.StreamWriter((Join-Path $OutDir 'inventory_errors.log'), $true, $utf8)
$summary = New-Object System.Collections.Generic.List[object]

function ConvertTo-IoPath([string]$p) { if ($p -match '^[A-Za-z]:\\') { '\\?\' + $p } else { $p } }

foreach ($root in $Roots) {
    $rootFull = $root.TrimEnd('\')
    $depth = if ($UnitDepth.ContainsKey($root)) { [int]$UnitDepth[$root] } else { 1 }
    $tag = ($rootFull -replace '[:\\]+', '_').Trim('_')
    $fw = $null
    if ($FileListRoots -contains $root) { $fw = New-Object System.IO.StreamWriter((Join-Path $OutDir "files_$tag.tsv"), $false, $utf8) }
    $acc = @{}
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($rootFull)
    $n = 0
    Write-Host "Scanning $rootFull (unit depth $depth)..."
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        $relDir = if ($dir.Length -gt $rootFull.Length) { $dir.Substring($rootFull.Length + 1) } else { '' }
        $parts = @(if ($relDir) { $relDir.Split('\') })
        # Unit key: first <depth> path levels (recursive unit, |R) or the shallower folder itself (loose files only, |L)
        if ($parts.Count -ge $depth) { $key = ($parts[0..($depth - 1)] -join '\') + '|R' } else { $key = $relDir + '|L' }
        $a = $acc[$key]
        # [0]files [1]bytes [2]newestTicks [3]oldestTicks [4]bytesOlderThanCutoff [5]futureDatedFiles
        if ($null -eq $a) { $a = [long[]]@(0, 0, [long]::MinValue, [long]::MaxValue, 0, 0); $acc[$key] = $a }
        try {
            foreach ($e in (New-Object System.IO.DirectoryInfo (ConvertTo-IoPath $dir)).EnumerateFileSystemInfos()) {
                if ($e.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                if ($e -is [System.IO.DirectoryInfo]) {
                    if ($ExcludeDirs -notcontains $e.Name) { $stack.Push("$dir\$($e.Name)") }
                    continue
                }
                $len = $e.Length
                $t = $e.LastWriteTimeUtc.Ticks
                $a[0]++
                $a[1] += $len
                if ($t -gt $futureTicks) { $a[5]++ } elseif ($t -gt $a[2]) { $a[2] = $t }
                if ($t -lt $a[3]) { $a[3] = $t }
                if ($t -lt $cutTicks) { $a[4] += $len }
                if ($fw) { $fw.WriteLine("$dir\$($e.Name)`t$len`t$($e.LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ss'))") }
                if ((++$n % 250000) -eq 0) { Write-Host "  $rootFull : $n files..." }
            }
        } catch { $errLog.WriteLine("$dir`t$($_.Exception.Message)") }
    }
    if ($fw) { $fw.Close() }
    foreach ($k in $acc.Keys) {
        $a = $acc[$k]
        if ($a[0] -eq 0) { continue }
        $unit, $mode = $k.Split('|')
        $coldPct = [math]::Round(100 * $a[4] / [math]::Max($a[1], 1), 1)
        $newest = if ($a[2] -eq [long]::MinValue) { '' } else { ([datetime]::new($a[2], 'Utc')).ToLocalTime().ToString('yyyy-MM-dd') }
        if ($a[5] -gt 0) { $tier = 'Review' }
        elseif ($a[2] -lt $cutTicks) { $tier = 'Cold' }
        elseif ($coldPct -ge $ReviewColdPct -and ($a[1] / 1GB) -ge $ReviewMinGB) { $tier = 'Review' }
        else { $tier = 'Hot' }
        $summary.Add([pscustomobject]@{
            Root        = $rootFull
            Unit        = $unit
            Recurse     = ($mode -eq 'R')
            Files       = $a[0]
            Bytes       = $a[1]
            SizeGB      = [math]::Round($a[1] / 1GB, 2)
            NewestWrite = $newest
            OldestWrite = ([datetime]::new($a[3], 'Utc')).ToLocalTime().ToString('yyyy-MM-dd')
            ColdPct     = $coldPct
            FutureDated = $a[5]
            Tier        = $tier
        })
    }
}
$errLog.Close()
$summary | Sort-Object Root, Unit | Export-Csv (Join-Path $OutDir 'summary_folders.csv') -NoTypeInformation -Encoding UTF8
$summary | Group-Object Root, Tier | ForEach-Object {
    [pscustomobject]@{
        Root   = $_.Group[0].Root
        Tier   = $_.Group[0].Tier
        Units  = $_.Count
        Files  = ($_.Group | Measure-Object Files -Sum).Sum
        SizeGB = [math]::Round(($_.Group | Measure-Object SizeGB -Sum).Sum, 1)
    }
} | Sort-Object Root, Tier | Format-Table -AutoSize
