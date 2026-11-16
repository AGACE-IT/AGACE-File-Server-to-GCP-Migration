#Requires -Version 5.1
# 09-Hash-Sample.ps1 - SHA-256 of a random sample (+10 largest files). Run on the SOURCE first,
# then on the VM with -SampleFrom <source csv> so both sides hash exactly the same relative paths.
param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$OutCsv,
    [string]$SampleFrom,
    [int]$Count = 200
)
$rootFull = $Root.TrimEnd('\')
if ($SampleFrom) {
    $rels = @((Import-Csv $SampleFrom).RelPath)
} else {
    $files = @(Get-ChildItem -LiteralPath $rootFull -Recurse -File -Force -ErrorAction SilentlyContinue)
    $rels = @($files | Get-Random -Count $Count) + @($files | Sort-Object Length -Descending | Select-Object -First 10) |
        ForEach-Object { $_.FullName.Substring($rootFull.Length + 1) } | Sort-Object -Unique
}
$rels | ForEach-Object {
    $rel = $_
    $hash = try { (Get-FileHash -LiteralPath (Join-Path $rootFull $rel) -Algorithm SHA256).Hash } catch { 'ERROR: ' + $_.Exception.Message }
    [pscustomobject]@{ RelPath = $rel; SHA256 = $hash }
} | Export-Csv $OutCsv -NoTypeInformation -Encoding UTF8
Write-Host "$($rels.Count) files hashed -> $OutCsv"
