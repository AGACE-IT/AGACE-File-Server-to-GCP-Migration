#Requires -Version 7.2
# 08-VM-Stamp-CustomTime.ps1 - runs ON THE GCP VM after the first SyncHot.
# Sets each object's Custom-Time to the first day of its file's LastWriteTime month, so lifecycle rules
# (daysSinceCustomTime) count the 5 years from the DOCUMENT date, not from the upload date.
# Custom-Time can never be moved earlier or removed: run -WhatIf first and test one accented file name.
param(
    [string]$HotLocal = 'E:\AGACE\Hot',
    [string]$HotBucket = 'gs://agace-operacion-activa',
    [string]$WorkDir = 'E:\AGACE\customtime',
    [switch]$WhatIf
)
$env:PYTHONUTF8 = '1'
if ($WorkDir -match '\s') { throw 'WorkDir must not contain spaces (cmd.exe redirection below).' }
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
$utf8 = [System.Text.UTF8Encoding]::new($false)
$writers = @{}
$skipped = [System.IO.StreamWriter]::new((Join-Path $WorkDir 'skipped-wildcard-names.txt'), $false, $utf8)
$root = (Resolve-Path -LiteralPath $HotLocal).Path.TrimEnd('\')
$opts = [System.IO.EnumerationOptions]@{ RecurseSubdirectories = $true; IgnoreInaccessible = $true; AttributesToSkip = 'ReparsePoint' }
foreach ($path in [System.IO.Directory]::EnumerateFiles($root, '*', $opts)) {
    $rel = $path.Substring($root.Length + 1)
    if ($rel.IndexOfAny([char[]]'*?[]') -ge 0) { $skipped.WriteLine($rel); continue }
    $month = [System.IO.File]::GetLastWriteTimeUtc($path).ToString('yyyy-MM')
    $w = $writers[$month]
    if (-not $w) { $w = [System.IO.StreamWriter]::new((Join-Path $WorkDir "urls-$month.txt"), $false, $utf8); $writers[$month] = $w }
    $w.WriteLine("$HotBucket/" + $rel.Replace('\', '/'))
}
$writers.Values | ForEach-Object { $_.Close() }
$skipped.Close()
foreach ($f in Get-ChildItem -LiteralPath $WorkDir -Filter 'urls-*.txt' | Sort-Object Name) {
    $ct = $f.BaseName.Substring(5) + '-01T00:00:00Z'
    $count = [System.IO.File]::ReadLines($f.FullName) | Measure-Object | Select-Object -ExpandProperty Count
    if ($WhatIf) { Write-Host "WhatIf: $count objects -> custom-time $ct"; continue }
    cmd /c "gcloud storage objects update --read-paths-from-stdin --custom-time=$ct < $($f.FullName) > $($f.FullName).log 2>&1"
    Write-Host "$ct : $count objects, exit $LASTEXITCODE"
}
