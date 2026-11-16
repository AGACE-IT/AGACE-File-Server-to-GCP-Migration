#Requires -Version 5.1
# 02-Find-Duplicates.ps1 - finds folders under RootA (G:) whose content (file names + sizes) is identical
# to a folder under RootB (W:), then confirms each candidate locally with robocopy /L (size + timestamp).
param(
    [string]$InvDir = 'C:\AGACE-Migration\inventory',
    [string]$RootA = 'G:\Seagate',
    [string]$RootB = 'W:\Sistemas',
    [int]$MaxDepth = 6,
    [double]$MinGB = 1
)
$ErrorActionPreference = 'Stop'
function Get-Tag([string]$r) { ($r.TrimEnd('\') -replace '[:\\]+', '_').Trim('_') }

function Get-DirSignatures([string]$root) {
    $tsv = Join-Path $InvDir "files_$(Get-Tag $root).tsv"
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $enc = New-Object System.Text.UTF8Encoding($false)
    $sig = @{}
    $skip = $root.TrimEnd('\').Length + 1
    $sr = New-Object System.IO.StreamReader($tsv, $enc)
    while ($null -ne ($line = $sr.ReadLine())) {
        $f = $line.Split("`t")
        $rel = $f[0].Substring($skip)
        $i = $rel.LastIndexOf('\')
        if ($i -lt 0) { continue }
        $size = [long]$f[1]
        # Order-independent folder signature: sum of 64-bit hashes of "name|size" (decimal = no overflow)
        $h = [decimal][BitConverter]::ToUInt64($md5.ComputeHash($enc.GetBytes($rel.Substring($i + 1).ToLowerInvariant() + '|' + $size)), 0)
        $dirs = @($rel.Substring(0, $i).Split('\'))
        $key = $null
        for ($d = 0; $d -lt [Math]::Min($dirs.Count, $MaxDepth); $d++) {
            $key = if ($null -eq $key) { $dirs[0] } else { $key + '\' + $dirs[$d] }
            $a = $sig[$key]
            if ($null -eq $a) { $a = [decimal[]]@(0, 0, 0); $sig[$key] = $a }
            $a[0]++
            $a[1] += $size
            $a[2] += $h
        }
    }
    $sr.Close()
    $sig
}

Write-Host "Building signatures for $RootA and $RootB ..."
$sigA = Get-DirSignatures $RootA
$sigB = Get-DirSignatures $RootB
$idxB = @{}
foreach ($k in $sigB.Keys) {
    $a = $sigB[$k]
    $fp = '{0}|{1}|{2}' -f $a[0], $a[1], $a[2]
    if (-not $idxB.ContainsKey($fp)) { $idxB[$fp] = New-Object System.Collections.Generic.List[string] }
    $idxB[$fp].Add($k)
}
$hits = @{}
foreach ($k in $sigA.Keys) {
    $a = $sigA[$k]
    if ($a[1] -lt ($MinGB * 1GB)) { continue }
    $fp = '{0}|{1}|{2}' -f $a[0], $a[1], $a[2]
    if ($idxB.ContainsKey($fp)) {
        $leaf = Split-Path $k -Leaf
        $best = @($idxB[$fp] | Where-Object { (Split-Path $_ -Leaf) -eq $leaf }) + @($idxB[$fp]) | Select-Object -First 1
        $hits[$k] = $best
    }
}
Write-Host "$($hits.Count) candidate folders >= $MinGB GB. Confirming with robocopy /L ..."
$result = foreach ($k in $hits.Keys) {
    $p = $k
    $nested = $false
    while (($i = $p.LastIndexOf('\')) -gt 0) { $p = $p.Substring(0, $i); if ($hits.ContainsKey($p)) { $nested = $true; break } }
    if ($nested) { continue }
    $pathA = "$($RootA.TrimEnd('\'))\$k"
    $pathB = "$($RootB.TrimEnd('\'))\$($hits[$k])"
    $null = & robocopy.exe $pathA $pathB /E /L /XJ /R:0 /W:0 /NJH /NJS /NFL /NDL /NP
    $rc = $LASTEXITCODE
    $verdict = switch ($rc) { 0 { 'Identical' } 1 { 'SameNameSize-DifferentDate' } default { 'Review' } }
    [pscustomobject]@{
        PathA     = $pathA
        PathB     = $pathB
        Files     = $sigA[$k][0]
        SizeGB    = [math]::Round($sigA[$k][1] / 1GB, 2)
        RobocopyL = $rc
        Verdict   = $verdict
    }
}
$result | Sort-Object SizeGB -Descending | Export-Csv (Join-Path $InvDir 'duplicates.csv') -NoTypeInformation -Encoding UTF8
$result | Group-Object Verdict | ForEach-Object {
    [pscustomobject]@{ Verdict = $_.Name; Folders = $_.Count; SizeGB = [math]::Round(($_.Group | Measure-Object SizeGB -Sum).Sum, 1) }
} | Format-Table -AutoSize
