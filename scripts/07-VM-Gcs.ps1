#Requires -Version 7.2
# 07-VM-Gcs.ps1 - runs ON THE GCP VM (PowerShell 7). Never uploads unverified data into the locked archive bucket.
#   UploadCold : uploads only Cold units whose Status = Verified in the published jobs.csv
#   SyncHot    : nightly incremental copy of the Hot volume to the versioned Standard bucket (no deletes)
#   Verify     : compares local file count/bytes vs GCS object count/bytes per top-level folder
param(
    [Parameter(Mandatory)][ValidateSet('UploadCold', 'SyncHot', 'Verify')][string]$Mode,
    [string]$ColdLocal = 'S:\AGACE\Cold',
    [string]$HotLocal = 'E:\AGACE\Hot',
    [string]$ColdShareUnc = '\\agace-gcp-fs01.agace.local\ColdStage$',
    [string]$ColdBucket = 'gs://agace-archivo-historico-2012-2020',
    [string]$HotBucket = 'gs://agace-operacion-activa',
    [string]$LogDir = 'E:\AGACE\gcs-logs'
)
$env:PYTHONUTF8 = '1'
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmm'

switch ($Mode) {
    'SyncHot' {
        & gcloud storage rsync $HotLocal $HotBucket --recursive *> (Join-Path $LogDir "hot-$stamp.log")
        Write-Host "SyncHot exit $LASTEXITCODE"
    }
    'UploadCold' {
        $doneFile = Join-Path $LogDir 'cold-uploaded.txt'
        $done = @{}
        if (Test-Path $doneFile) { Get-Content $doneFile | ForEach-Object { $done[$_] = $true } }
        $jobs = @(Import-Csv (Join-Path $ColdLocal '_control\jobs.csv') | Where-Object { $_.Tier -eq 'Cold' -and $_.Status -eq 'Verified' })
        foreach ($j in $jobs) {
            if ($done.ContainsKey($j.JobId)) { continue }
            $rel = $j.Destination.Substring($ColdShareUnc.Length).TrimStart('\')
            $gcsArgs = @('storage', 'rsync', (Join-Path $ColdLocal $rel), ("$ColdBucket/" + ($rel -replace '\\', '/')))
            if ($j.Recurse -eq 'True') { $gcsArgs += '--recursive' }
            & gcloud @gcsArgs *> (Join-Path $LogDir "cold-$($j.JobId)-$stamp.log")
            if ($LASTEXITCODE -eq 0) { Add-Content $doneFile $j.JobId } else { Write-Warning "$($j.JobId) upload failed (exit $LASTEXITCODE)" }
        }
        Write-Host "UploadCold: $($jobs.Count) verified cold units considered."
    }
    'Verify' {
        $pairs = @(@($HotLocal, $HotBucket), @($ColdLocal, $ColdBucket))
        $out = foreach ($pr in $pairs) {
            Get-ChildItem -LiteralPath $pr[0] -Directory | Where-Object Name -ne '_control' | ForEach-Object {
                $m = Get-ChildItem -LiteralPath $_.FullName -Recurse -File -Force | Measure-Object Length -Sum
                $prefix = "$($pr[1])/$($_.Name)"
                $gBytes = [long](((& gcloud storage du -s $prefix) | Select-Object -First 1).Trim() -split '\s+')[0]
                $gCount = @(& gcloud storage ls "$prefix/**").Count
                [pscustomobject]@{
                    Bucket = $pr[1]; Folder = $_.Name; LocalFiles = $m.Count; GcsObjects = $gCount
                    LocalBytes = [long]$m.Sum; GcsBytes = $gBytes; Match = ($m.Count -eq $gCount -and [long]$m.Sum -eq $gBytes)
                }
            }
        }
        $out | Export-Csv (Join-Path $LogDir "verify-$stamp.csv") -NoTypeInformation -Encoding utf8BOM
        $out | Format-Table -AutoSize
    }
}
