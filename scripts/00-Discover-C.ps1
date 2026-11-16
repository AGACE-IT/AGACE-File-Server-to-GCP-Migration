#Requires -Version 5.1
# 00-Discover-C.ps1 - lists candidate BUSINESS folders on C: (OS/app folders excluded). Read-only.
param([string]$OutDir = 'C:\AGACE-Migration\inventory')
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

$osDirs = @('Windows', 'Program Files', 'Program Files (x86)', 'ProgramData', 'PerfLogs', 'Recovery', 'Boot', 'Intel',
            '$Recycle.Bin', 'System Volume Information', '$WinREAgent', '$SysReset', '$Windows.~BT', '$Windows.~WS',
            'Windows.old', 'Config.Msi', 'MSOCache', 'Documents and Settings', 'AGACE-Migration', 'Users')
$profileSkip = @('AppData', 'Application Data', 'Local Settings', 'Cookies', 'NetHood', 'PrintHood', 'Recent',
                 'SendTo', 'Start Menu', 'Templates', 'My Documents', 'OneDrive')
$isReparse = { param($d) [bool]($d.Attributes -band [IO.FileAttributes]::ReparsePoint) }

$cands = New-Object System.Collections.Generic.List[string]
Get-ChildItem -LiteralPath 'C:\' -Directory -Force |
    Where-Object { $osDirs -notcontains $_.Name -and -not (& $isReparse $_) } |
    ForEach-Object { $cands.Add($_.FullName) }
Get-ChildItem -LiteralPath 'C:\Users' -Directory -Force |
    Where-Object { @('Default', 'Default User', 'All Users') -notcontains $_.Name -and -not (& $isReparse $_) } |
    ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Directory -Force -ErrorAction SilentlyContinue } |
    Where-Object { $profileSkip -notcontains $_.Name -and -not (& $isReparse $_) } |
    ForEach-Object { $cands.Add($_.FullName) }

$rows = foreach ($c in $cands) {
    $m = Get-ChildItem -LiteralPath $c -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
    [pscustomobject]@{ Path = $c; Files = $m.Count; SizeGB = [math]::Round(($m.Sum / 1GB), 2); Include = '' }
}
$rows = $rows | Sort-Object SizeGB -Descending
$rows | Export-Csv (Join-Path $OutDir 'C_candidates.csv') -NoTypeInformation -Encoding UTF8
$rows | Format-Table -AutoSize
