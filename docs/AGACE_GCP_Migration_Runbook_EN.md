# AGACE Asesoría Y Gestoría Al Comercio Exterior S.C.
# Runbook: Multi-Drive Windows File Server → Google Cloud (Hot/Cold)

| Item | Value |
|---|---|
| Document | AGACE-MIG-GCP-001, v1.0 (draft for AGACE review) |
| Date | 2026-11-16 |
| Scope | Source drives C: (business data only), D:\Informacion, F:\Lacie, G:\Seagate, W:\Sistemas (≈ 11.2 TB as shown by Windows) |
| Target | Windows Server VM on GCP (Hot / FM2 data) + Cloud Storage (versioned copy of Hot + Archive tier for 2012–2020) |
| Tooling | Robocopy (Windows-native), PowerShell 5.1 on the source, PowerShell 7 + gcloud CLI on the VM |
| Spanish version | `AGACE_Runbook_Migracion_GCP_ES-MX.md` (same commands; for AGACE approval) |

All scripts in this runbook are also delivered as files in `scripts/` and `gcp/`. Copy `scripts\*.ps1` to `C:\AGACE-Migration\scripts` on the source server and `07-*.ps1`, `08-*.ps1`, `09-*.ps1` to `E:\AGACE\scripts` on the VM. They are identical in both language versions of the runbook.

---

## 0. Architecture, placeholders and assumptions

### 0.1 Target architecture

```
 AGACE Matamoros (on-prem)                     Google Cloud - northamerica-south1 (Queretaro)
 +-----------------------------+   HA VPN      +------------------------------------------------+
 | AGACE-FS01 (source)         |  (IPsec)      | VM agace-gcp-fs01 (Windows Server 2022)        |
 |  C:  approved folders only  | ------------> |  E: agace-hot (pd-balanced)   share Hot$       |--+--> gs://agace-operacion-activa
 |  D:\Informacion             |  SMB 3 / 445  |  S: agace-cold-staging (pd-std) share ColdStage$|  |    STANDARD, versioned, lifecycle:
 |  F:\Lacie    (USB)          |  robocopy     |     (temporary, deleted after Gate A)          |  |    COLDLINE @5y, ARCHIVE @7y
 |  G:\Seagate  (USB)          |               +------------------------------------------------+  |
 |  W:\Sistemas                |                                                                   +--> gs://agace-archivo-historico-2012-2020
 +-----------------------------+                                                                        ARCHIVE from day 0, retention
                                                                                                         policy (locked after approval)
```

Data flow:

1. **Hot** units (newest file dated 2021-01-01 or later) go by robocopy to `E:\AGACE\Hot` on the VM. FM2 users work there after cutover. Every night the VM copies E: to the versioned Standard bucket (inside GCP, so no WAN traffic).
2. **Cold** units (nothing modified since 2020) go by robocopy to the temporary staging disk `S:\AGACE\Cold`, are verified, and then upload to the Archive bucket. The staging disk is deleted afterwards, so cold data is never paid for on a VM disk long-term.

### 0.2 Placeholders (replace before execution)

| Placeholder used in this runbook | Meaning |
|---|---|
| `AGACE-FS01`, `192.168.10.20` | Source Windows server and its IP |
| `agace.local` / `AGACE\` | Active Directory domain (DNS / NetBIOS) |
| `AGACE\svc-migration` | Migration service account (robocopy, scheduled tasks) |
| `agace-migracion` | GCP project ID |
| `northamerica-south1`, `northamerica-south1-a` | GCP region / zone (Querétaro, Mexico) |
| `agace-vpc`, `agace-subnet-mx`, `10.50.0.0/24` | VPC, subnet and range |
| `agace-gcp-fs01.agace.local`, `10.50.0.10` | Destination VM |
| `sa-agace-fs@agace-migracion.iam.gserviceaccount.com` | VM service account |
| `gs://agace-operacion-activa` | Hot bucket (bucket names are global: add a unique suffix) |
| `gs://agace-archivo-historico-2012-2020` | Cold/archive bucket |
| `2021-01-01` / `20210101` | Hot/Cold cutoff (file LastWriteTime) |
| N1 = Mon 2026-11-23 … N10 = Wed 2026-12-02; buffer nights Dec 3–4; cutover Sat 2026-12-05 | Example calendar |
| `C:\AGACE-Migration\{scripts,inventory,jobs,logs,monitor}` | Working folders on the source |

### 0.3 Assumptions to confirm before Gate 1

| # | Assumption | If it is not true |
|---|---|---|
| A1 | Source and VM are in the same AD domain, so robocopy can copy NTFS ACLs for Hot data (`/COPY:DATSO`). | Workgroup: run `04-Run-Robocopy.ps1 -HotCopy /COPY:DAT` and re-apply share and NTFS permissions on the VM. |
| A2 | Source OS is Windows Server 2012 R2 or later (SMB 3.x, PowerShell 5.1). | 2008 R2: install WMF 5.1 and expect lower throughput (SMB 2.1). |
| A3 | F: (LaCie) and G: (Seagate) are external USB disks. | We treat them as the drives most likely to fail (see 1.1 and 6.3). |
| A4 | FM2 data is plain files. | Live databases (SQL Server `.mdf/.ldf/.ndf`, e.g. FM2 back end or CONTPAQi), open `.pst/.ost` files, and similar must move by native backup/restore. Robocopy must not copy them (see 1.2). |
| A5 | Uplink and VPN can sustain ≥ 450–550 Mbps at night. | The full 11.2 TB will not fit in 10 nights. Run Hot first and move Cold after cutover (Section 5). |
| A6 | Data must stay in Mexico, so the region is `northamerica-south1`. | Without a residency requirement, `us-south1` (Dallas) usually has lower latency from Matamoros. Check that the machine series and disk types you need exist in the chosen region. |
| A7 | The legal retention term (Ley Aduanera, CFF and the 2026 reform) as interpreted by AGACE's compliance counsel. | This runbook uses file **LastWriteTime** as a stand-in for document date. Counsel must confirm the cutoff, the 5-year clock (usually from the date of the operation/pedimento) and the lock period before 3.4. |
| A8 | Matamoros follows US-style DST. The VM must use the same Windows time zone as the source (`tzutil /g`). | Otherwise the `/RH` windows and the task schedules drift by one hour. |

### 0.4 Design decisions

* **Copy only, never move.** No `/MOV`, and no `/MIR` or `/PURGE` until cutover. A USB disk that remounts empty would make `/MIR` wipe the destination. The source stays authoritative until sign-off.
* **Migration unit = folder.** Each top-level (or second-level) folder is classified, copied, logged, verified and retried as a single unit. One log per unit gives a per-client audit trail. A pedimento file is never split from the rest of its expediente.
* **Cutover only waits for Hot.** FM2 needs only Hot data. Cold is a static archive and can keep loading after cutover with no business impact. This is the main lever if bandwidth falls short.
* **Classify at load time instead of relying on lifecycle "age".** GCS measures `age` from upload, not from the file date (3.1). Cold data is written straight to Archive. Hot data gets a Custom-Time stamp.

---

## 1. Pre-migration inventory

### 1.1 Pre-flight on AGACE-FS01 (T-7 days)

```powershell
# Disk / volume health - any 'Warning', 'Unhealthy' or ReadErrorsUncorrected > 0 on F:/G: => Section 6.3 BEFORE copying
Get-PhysicalDisk | Sort-Object DeviceId | Format-Table DeviceId, FriendlyName, BusType, MediaType, HealthStatus, OperationalStatus, @{n='SizeTB';e={[math]::Round($_.Size/1TB,2)}}
Get-PhysicalDisk | Get-StorageReliabilityCounter | Format-Table DeviceId, Temperature, ReadErrorsUncorrected, ReadErrorsTotal, PowerOnHours
Get-Volume | Where-Object DriveLetter | Format-Table DriveLetter, FileSystemLabel, FileSystem, HealthStatus, @{n='UsedTB';e={[math]::Round(($_.Size-$_.SizeRemaining)/1TB,2)}}

# Keep USB disks awake for the whole migration (USB selective suspend / disk idle are classic night-time disconnects)
powercfg /change disk-timeout-ac 0
powercfg /change standby-timeout-ac 0
powercfg /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0
powercfg /setactive SCHEME_CURRENT

# Versions and time zone (record the output in the checklist)
$PSVersionTable.PSVersion; (Get-CimInstance Win32_OperatingSystem).Caption; tzutil /g
```

Also: in Device Manager, untick "Allow the computer to turn off this device" on the USB Root Hubs. Set Windows Update to download-only (no automatic restart) on the source and VM until cutover, and create the working folders `C:\AGACE-Migration\{scripts,inventory,jobs,logs,monitor}`.

USB enclosures often hide SMART data. If F: or G: shows no reliability counters, run the vendor tool (SeaTools / LaCie Toolkit) before N1.

### 1.2 C: drive: business data only

C: holds the OS and applications (~650 GB). Never use `C:\` as a robocopy source. The script below lists candidate business folders and excludes Windows, Program Files, ProgramData, Recovery, `$Recycle.Bin`, System Volume Information, profile AppData and similar.

`scripts/00-Discover-C.ps1`

```powershell
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
```

Open `C_candidates.csv`, mark `Include = Y` on the folders AGACE approves, and add each approved path as an extra root:

* in `01-Inventory.ps1 -Roots` / `-UnitDepth`, e.g. `'C:\Contabilidad'`
* in `03-Build-Jobs.ps1 -RootMap`, e.g. `'C:\Contabilidad' = 'C_Datos\Contabilidad'` or `'C:\Users\jperez\Documents' = 'C_Datos\Users\jperez\Documents'`

Find live database and mailbox files on every drive. These must go by native backup, not robocopy. Robocopy `/L` lists them quickly and copies nothing:

```powershell
foreach ($r in 'C:\', 'D:\Informacion', 'F:\Lacie', 'G:\Seagate', 'W:\Sistemas') {
  robocopy $r NULL *.mdf *.ldf *.ndf *.pst *.ost *.accdb *.mdb /S /L /XJ /R:0 /W:0 /NJH /NDL /FP /BYTES /NC `
    /XD Windows "Program Files" "Program Files (x86)" '$RECYCLE.BIN' "System Volume Information" `
    /UNILOG+:C:\AGACE-Migration\inventory\db_and_mail_files.log
}
```

### 1.3 Inventory and Hot/Cold classification

The inventory script reads metadata only and writes nothing to the source drives. It walks each root with .NET (long-path aware, skips junctions, `$RECYCLE.BIN` and `System Volume Information`) and builds one row per **migration unit**:

* **Recursive unit (`Recurse=True`):** the folder at `UnitDepth` levels below the root, e.g. `W:\Sistemas\Clientes\ACME` with depth 2.
* **Loose-files unit (`Recurse=False`):** files sitting directly in a shallower folder, e.g. files directly inside `W:\Sistemas\Clientes`.

How to choose `UnitDepth`: run with depth 1 first. Use depth 2 for large containers (`Clientes`, `Respaldos`, `Pedimentos`). Target 200–3,000 units and keep each unit **≤ 80 % of one night's capacity** (≈ 0.9 TB at 50 MB/s). That way a unit nearly always finishes inside one window.

`scripts/01-Inventory.ps1`

```powershell
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
```

```powershell
Set-Location C:\AGACE-Migration\scripts
.\01-Inventory.ps1 -Roots 'D:\Informacion','F:\Lacie','G:\Seagate','W:\Sistemas','C:\Contabilidad' `
  -UnitDepth @{ 'D:\Informacion'=1; 'F:\Lacie'=1; 'G:\Seagate'=2; 'W:\Sistemas'=2; 'C:\Contabilidad'=1 }
```

**Classification rules (per unit, using the newest *file* in the whole subtree):**

| Condition | Tier | Action |
|---|---|---|
| `FutureDated > 0` (file dated in the future: bad clock or unzipped archive) | `Review` | Decide manually |
| `NewestWrite < 2021-01-01` | `Cold` | Archive (2012–2020) |
| `ColdPct ≥ 80` and `SizeGB ≥ 50` | `Review` | Mostly old with a few recent files: choose `Hot`, `Cold`, `Split` or `Exclude` |
| otherwise | `Hot` | Active / FM2 |

Rules for resolving `Review` rows:

* `Hot`: keeps the expediente together. This is the default for active clients.
* `Split`: copies files dated 2021 or later to Hot and older files to Cold, using robocopy `/MAXAGE:20210101` and `/MINAGE:20210101`. Use it only where folder integrity does not matter (scan dumps, exports).
* `Exclude`: only for proven duplicates and only with written approval (1.4). Excluded units are recorded in `jobs\excluded_units.csv`.

Things to watch:

* Folder LastWriteTime is unreliable (it only changes when direct children change). The script therefore uses the newest file date in the subtree.
* A unit where `OldestWrite = NewestWrite` and the file count is large usually means the files were copied with a tool that reset timestamps. Classify it by its folder name (e.g. `2016`) instead.
* Robocopy (`/COPY:DAT`, `/DCOPY:DAT`) and `gcloud storage rsync` both keep modification times. The classification therefore stays reproducible on the destination.

To edit tiers, use PowerShell. Excel turns the `Bytes` column into `1.2E+12` when it saves the file, which corrupts it:

```powershell
$f = 'C:\AGACE-Migration\inventory\summary_folders.csv'
$s = Import-Csv $f
$s | Where-Object { $_.Root -eq 'W:\Sistemas' -and $_.Unit -like 'Clientes\ACME*' } | ForEach-Object { $_.Tier = 'Hot' }
$s | Export-Csv $f -NoTypeInformation -Encoding UTF8
$s | Group-Object Tier | Select-Object Name, Count, @{n='TB';e={[math]::Round(($_.Group | Measure-Object Bytes -Sum).Sum/1e12,2)}}
```

### 1.4 Duplicate folders across G:\Seagate and W:\Sistemas

G:\Seagate (4.29 TB) is probably, at least in part, a backup of W:\Sistemas (4.89 TB). Duplicates are confirmed in three levels, each run locally on the source with no WAN traffic:

| Level | Method | Cost |
|---|---|---|
| L1 Signature | For every folder ≥ 1 GB (depth ≤ 6): file count + total bytes + an order-independent hash of every file's *name + size*. It finds a copy even when it sits under a different parent, e.g. `G:\Seagate\Respaldo2019\Clientes` = `W:\Sistemas\Clientes`. | Reads the TSV only, minutes |
| L2 `robocopy /L` | Confirms name + size + **timestamp** for each candidate pair. Exit 0 = identical. | Metadata, minutes |
| L3 SHA-256 sample | `09-Hash-Sample.ps1`: 200 random files + the 10 largest per pair. Mandatory for pairs > 100 GB and for `SameNameSize-DifferentDate`. | Reads the sample only |

`scripts/02-Find-Duplicates.ps1`

```powershell
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
```

```powershell
.\02-Find-Duplicates.ps1 -RootA 'G:\Seagate' -RootB 'W:\Sistemas' -MaxDepth 6 -MinGB 1
# L3 content proof for one pair (both drives are local)
.\09-Hash-Sample.ps1 -Root 'G:\Seagate\Respaldo2019\Clientes' -OutCsv C:\AGACE-Migration\inventory\hash_pair01_G.csv
.\09-Hash-Sample.ps1 -Root 'W:\Sistemas\Clientes' -SampleFrom C:\AGACE-Migration\inventory\hash_pair01_G.csv -OutCsv C:\AGACE-Migration\inventory\hash_pair01_W.csv
Compare-Object (Import-Csv C:\AGACE-Migration\inventory\hash_pair01_G.csv) (Import-Csv C:\AGACE-Migration\inventory\hash_pair01_W.csv) -Property RelPath, SHA256
# no output = PASS
```

`scripts/09-Hash-Sample.ps1`

```powershell
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
```

**Decision per `Identical` pair:**

* **Strategy A, seed inside GCP (recommended, default).** W: crosses the WAN once. Inside the VM it is cloned into the G: destination (2.6). The G: job then finds every file "same" and sends almost nothing, yet the G: structure stays a 1:1 copy for auditors. Storing the duplicate in Archive costs about US$1.2 per TB-month. The saving is WAN time, which is the scarce resource.
* **Strategy B, exclude.** Set the G: unit's tier to `Exclude`. This saves WAN time and storage, but the G: copy will not exist in GCP. It needs written approval from AGACE compliance. Keep `duplicates.csv` in the archive bucket (`_manifest/`) as evidence.

Partial overlaps (G: is an *older* snapshot of a folder that has since changed on W:) produce different signatures and are copied normally. That is deliberately conservative, because a file deleted from production may survive only on the backup drive.

WAN bytes saved = sum of `SizeGB` for the `Identical` pairs used (`D_dup` in Section 5). The same method can compare F:\Lacie against W:\Sistemas: add `'F:\Lacie'` to `-FileListRoots` and run with `-RootA 'F:\Lacie'`.

### 1.5 Build the job list

`scripts/03-Build-Jobs.ps1`

```powershell
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
```

```powershell
.\03-Build-Jobs.ps1     # prints Jobs and TB per tier -> enter Hot TB / Cold TB in Section 5
```

Order: Hot before Cold. Within a tier the drive order is D:, C:, W:, F:, G:. G: goes last so its duplicates can be seeded from W:. Hold the G: units that are part of an `Identical` pair until seeding (2.6) is done:

```powershell
$d = Import-Csv C:\AGACE-Migration\inventory\duplicates.csv | Where-Object Verdict -eq 'Identical'
$jf = 'C:\AGACE-Migration\jobs\jobs.csv'; $j = Import-Csv $jf
foreach ($x in $j) { if ($d | Where-Object { $x.Source -like "$($_.PathA)*" -or $_.PathA -like "$($x.Source)\*" }) { $x.Status = 'Hold' } }
$j | Export-Csv $jf -NoTypeInformation -Encoding UTF8
```

**Gate 1, inventory approved:** `summary_folders.csv` has no `Review` rows; AGACE has signed off the C: allow-list, the Hot/Cold totals, any `Exclude` decisions and the DB/PST list; `jobs.csv` has been generated.

---

## 2. Robocopy: mapping each drive to its GCP destination

### 2.1 GCP landing zone (Cloud Shell, T-7 days)

```bash
PROJECT=agace-migracion; REGION=northamerica-south1; ZONE=northamerica-south1-a
gcloud config set project $PROJECT
gcloud services enable compute.googleapis.com storage.googleapis.com
gcloud compute networks create agace-vpc --subnet-mode=custom
gcloud compute networks subnets create agace-subnet-mx --network=agace-vpc --region=$REGION \
  --range=10.50.0.0/24 --enable-private-ip-google-access
# HA VPN (2 tunnels + Cloud Router/BGP) to the Matamoros firewall per the Cloud VPN guide.
# On the on-prem firewall: TCP MSS clamping 1360 (avoids IPsec fragmentation, which kills SMB throughput).
gcloud compute firewall-rules create agace-allow-smb-onprem --network=agace-vpc --direction=INGRESS \
  --action=ALLOW --rules=tcp:445 --source-ranges=192.168.10.20/32 --target-tags=agace-fs
gcloud compute firewall-rules create agace-allow-iap-rdp --network=agace-vpc --direction=INGRESS \
  --action=ALLOW --rules=tcp:3389 --source-ranges=35.235.240.0/20 --target-tags=agace-fs
gcloud iam service-accounts create sa-agace-fs --display-name="AGACE file server VM"
gcloud compute machine-types list --zones=$ZONE --filter="name=n2-standard-8"   # confirm availability
gcloud compute instances create agace-gcp-fs01 --zone=$ZONE --machine-type=n2-standard-8 \
  --image-family=windows-2022 --image-project=windows-cloud --boot-disk-size=200GB --boot-disk-type=pd-balanced \
  --network-interface=subnet=agace-subnet-mx,private-network-ip=10.50.0.10,no-address \
  --tags=agace-fs --service-account=sa-agace-fs@$PROJECT.iam.gserviceaccount.com --scopes=cloud-platform \
  --create-disk=name=agace-hot,size=6000GB,type=pd-balanced,auto-delete=no \
  --create-disk=name=agace-cold-staging,size=8000GB,type=pd-standard,auto-delete=no
gcloud compute resource-policies create snapshot-schedule agace-daily-0600 --region=$REGION \
  --max-retention-days=14 --on-source-disk-delete=keep-auto-snapshots --daily-schedule --start-time=12:00
gcloud compute disks add-resource-policies agace-hot --resource-policies=agace-daily-0600 --zone=$ZONE
```

Sizing: `agace-hot = Hot TB × 1.3` and `agace-cold-staging = Cold TB × 1.1`, using the output of 1.5. Persistent disks can grow online but never shrink, so start at the computed size. The domain controller must be reachable over the VPN for the domain join (DNS 53, Kerberos 88, LDAP 389, SMB 445, RPC 135 + 49152-65535). The snapshot runs at 12:00 UTC, which is 06:00 in Matamoros (CST).

On the VM (RDP through IAP, as a domain admin):

```powershell
tzutil /s "Central Standard Time"          # must equal 'tzutil /g' on AGACE-FS01
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -Value 1
Add-Computer -DomainName agace.local -Credential (Get-Credential) -Restart
# after reboot - match GCE disks by SerialNumber (= disk name) before formatting
Get-Disk | Format-Table Number, SerialNumber, PartitionStyle, @{n='GB';e={$_.Size/1GB}}
$hot  = (Get-Disk | Where-Object SerialNumber -like '*agace-hot*').Number
$cold = (Get-Disk | Where-Object SerialNumber -like '*agace-cold-staging*').Number
Initialize-Disk -Number $hot -PartitionStyle GPT
New-Partition -DiskNumber $hot -UseMaximumSize -DriveLetter E | Format-Volume -FileSystem NTFS -NewFileSystemLabel AGACE-HOT -Confirm:$false
Initialize-Disk -Number $cold -PartitionStyle GPT
New-Partition -DiskNumber $cold -UseMaximumSize -DriveLetter S | Format-Volume -FileSystem NTFS -NewFileSystemLabel AGACE-COLD-STAGING -Confirm:$false
New-Item -ItemType Directory -Force E:\AGACE\Hot, E:\AGACE\scripts, E:\AGACE\gcs-logs, S:\AGACE\Cold\_control | Out-Null
New-SmbShare -Name 'Hot$'       -Path 'E:\AGACE\Hot'  -FullAccess 'AGACE\svc-migration', 'BUILTIN\Administrators' -CachingMode None
New-SmbShare -Name 'ColdStage$' -Path 'S:\AGACE\Cold' -FullAccess 'AGACE\svc-migration', 'BUILTIN\Administrators' -CachingMode None
Add-LocalGroupMember -Group 'Backup Operators' -Member 'AGACE\svc-migration'
gcloud version      # gcloud CLI is preinstalled on GCE Windows images; also install PowerShell 7.4 LTS (MSI) for 07/08
```

NTFS with the default 4 KB clusters supports volumes up to 16 TB. If the Hot disk must be larger, add `-AllocationUnitSize 8192` or more.

### 2.2 Source → destination map

| Source | Tier | Robocopy destination (UNC from AGACE-FS01) | Path on VM | Final location in GCS |
|---|---|---|---|---|
| `C:\<approved folder>` | Hot | `\\agace-gcp-fs01.agace.local\Hot$\C_Datos\<folder>` | `E:\AGACE\Hot\C_Datos\…` | `gs://agace-operacion-activa/C_Datos/…` |
| `C:\<approved folder>` | Cold | `\\agace-gcp-fs01.agace.local\ColdStage$\C_Datos\<folder>` | `S:\AGACE\Cold\C_Datos\…` | `gs://agace-archivo-historico-2012-2020/C_Datos/…` |
| `D:\Informacion\<unit>` | Hot / Cold | `…\Hot$\D_Informacion\<unit>` / `…\ColdStage$\D_Informacion\<unit>` | `E:\AGACE\Hot\D_Informacion\…` / `S:\AGACE\Cold\D_Informacion\…` | `…/D_Informacion/…` |
| `F:\Lacie\<unit>` | Hot / Cold | `…\Hot$\F_Lacie\<unit>` / `…\ColdStage$\F_Lacie\<unit>` | `E:\…\F_Lacie` / `S:\…\F_Lacie` | `…/F_Lacie/…` |
| `G:\Seagate\<unit>` | Hot / Cold | `…\Hot$\G_Seagate\<unit>` / `…\ColdStage$\G_Seagate\<unit>` | `E:\…\G_Seagate` / `S:\…\G_Seagate` | `…/G_Seagate/…` |
| `W:\Sistemas\<unit>` | Hot / Cold | `…\Hot$\W_Sistemas\<unit>` / `…\ColdStage$\W_Sistemas\<unit>` | `E:\…\W_Sistemas` / `S:\…\W_Sistemas` | `…/W_Sistemas/…` |
| **Never copied** | – | `C:\Windows`, `Program Files*`, `ProgramData`, `Users\*\AppData`, `$RECYCLE.BIN`, `System Volume Information`, `$WinREAgent`, `pagefile.sys`, `hiberfil.sys`, `swapfile.sys`, live DB/PST files | – | – |

The relative path below each drive folder is the same on E:, S: and in both buckets. Any file can be traced from source to VM to GCS with a single path.

### 2.3 Standard switch set

| Switch | Reason |
|---|---|
| `/E` | Recurse, including empty folders. **Not `/MIR`** during migration. |
| `/COPY:DATSO` (Hot) / `/COPY:DAT` (Cold) | Data, attributes and timestamps, plus NTFS ACLs and owner for Hot. GCS cannot hold NTFS ACLs, so Cold does not copy them. |
| `/DCOPY:DAT` | Keeps folder timestamps, which the yearly aging process needs. |
| `/B` | Backup mode: reads files whatever their ACL. Requires an elevated process and Backup Operators/Administrators membership. |
| `/MT:32` (`/MT:8` on F:/G:) | Threads hide WAN latency for small files. Fewer threads on spinning USB disks avoid seek thrash. |
| `/R:2 /W:5` | The default of 1,000,000 retries × 30 s would let one locked file stall the night. |
| `/XJ` | Skips junctions/symlinks, which prevents loops such as "Application Data". |
| `/XD $RECYCLE.BIN "System Volume Information" $WinREAgent Config.Msi RECYCLER` | Hidden system folders, matched by name at any depth. |
| `/XF pagefile.sys hiberfil.sys swapfile.sys Thumbs.db ~$*` | OS files, thumbnail caches, Office lock files. |
| `/RH:2200-0500 /PF` | New files start only inside the window, checked per file. |
| `/UNILOG:<file>` | Unicode log, so ñ/á/é in names stay readable. One log per unit. |
| `/NP /NDL /FP /BYTES` | Compact log with full paths and exact byte counts. |
| *Not used:* `/Z` | Restartable mode slows down many small files. An interrupted file is simply recopied whole the next night. |
| *Not used:* `/IPG` | Cannot be combined with `/MT`. Use the QoS cap in 4.4 instead. |
| *Not used:* `/MIR`, `/MOV`, `/PURGE` | `/PURGE` is used only at cutover, Hot only, after a `/L` preview (2.5). |

### 2.4 Exact commands per drive

The orchestrator (2.5) generates these commands for every unit. The same lines can be run by hand for the pilot or to rerun a single unit. Do not end a quoted source with a backslash: robocopy reads `"D:\"` as `D:"`.

```bat
:: ===== Common (cmd.exe) =====
set HOT=\\agace-gcp-fs01.agace.local\Hot$
set COLD=\\agace-gcp-fs01.agace.local\ColdStage$
set LOG=C:\AGACE-Migration\logs\manual
set RC_COMMON=/DCOPY:DAT /B /R:2 /W:5 /XJ /NP /NDL /FP /BYTES /RH:2200-0500 /PF /XD "$RECYCLE.BIN" "System Volume Information" "$WinREAgent" "Config.Msi" "RECYCLER" /XF pagefile.sys hiberfil.sys swapfile.sys Thumbs.db "~$*"

:: ===== C: (approved business folders only - example C:\Contabilidad, Hot) =====
robocopy "C:\Contabilidad" "%HOT%\C_Datos\Contabilidad" /E /COPY:DATSO /MT:32 %RC_COMMON% /UNILOG:%LOG%\C_Contabilidad.log

:: ===== D:\Informacion (~232 GB) - Hot unit / Cold unit =====
robocopy "D:\Informacion\<Unit>" "%HOT%\D_Informacion\<Unit>"  /E /COPY:DATSO /MT:32 %RC_COMMON% /UNILOG:%LOG%\D_<Unit>.log
robocopy "D:\Informacion\<Unit>" "%COLD%\D_Informacion\<Unit>" /E /COPY:DAT   /MT:32 %RC_COMMON% /UNILOG:%LOG%\D_<Unit>.log

:: ===== F:\Lacie (~1.15 TB, USB: 8 threads) =====
robocopy "F:\Lacie\<Unit>" "%HOT%\F_Lacie\<Unit>"  /E /COPY:DATSO /MT:8 %RC_COMMON% /UNILOG:%LOG%\F_<Unit>.log
robocopy "F:\Lacie\<Unit>" "%COLD%\F_Lacie\<Unit>" /E /COPY:DAT   /MT:8 %RC_COMMON% /UNILOG:%LOG%\F_<Unit>.log

:: ===== G:\Seagate (~4.29 TB, USB: 8 threads; after seeding 2.6) =====
robocopy "G:\Seagate\<Unit>" "%HOT%\G_Seagate\<Unit>"  /E /COPY:DATSO /MT:8 %RC_COMMON% /UNILOG:%LOG%\G_<Unit>.log
robocopy "G:\Seagate\<Unit>" "%COLD%\G_Seagate\<Unit>" /E /COPY:DAT   /MT:8 %RC_COMMON% /UNILOG:%LOG%\G_<Unit>.log

:: ===== W:\Sistemas (~4.89 TB) =====
robocopy "W:\Sistemas\<Unit>" "%HOT%\W_Sistemas\<Unit>"  /E /COPY:DATSO /MT:32 %RC_COMMON% /UNILOG:%LOG%\W_<Unit>.log
robocopy "W:\Sistemas\<Unit>" "%COLD%\W_Sistemas\<Unit>" /E /COPY:DAT   /MT:32 %RC_COMMON% /UNILOG:%LOG%\W_<Unit>.log

:: ===== Loose-files unit (Recurse=False): files directly in the folder, NO /E =====
robocopy "W:\Sistemas\Clientes" "%HOT%\W_Sistemas\Clientes" /COPY:DATSO /MT:32 %RC_COMMON% /UNILOG:%LOG%\W_Clientes_files.log

:: ===== Split unit: same source, two commands =====
robocopy "W:\Sistemas\<Unit>" "%HOT%\W_Sistemas\<Unit>"  /E /COPY:DATSO /MAXAGE:20210101 /MT:32 %RC_COMMON% /UNILOG:%LOG%\W_<Unit>_hot.log
robocopy "W:\Sistemas\<Unit>" "%COLD%\W_Sistemas\<Unit>" /E /COPY:DAT   /MINAGE:20210101 /MT:32 %RC_COMMON% /UNILOG:%LOG%\W_<Unit>_cold.log

:: ===== Daily-work sync (same as Hot baseline, window 23:59-04:00) =====
::   replace /RH:2200-0500 with /RH:2359-0400 in RC_COMMON

:: ===== Verification (no copy): exit 0 = destination identical, 2 = only extras at destination =====
robocopy "W:\Sistemas\<Unit>" "%HOT%\W_Sistemas\<Unit>" /E /L /COPY:DATSO /MT:32 %RC_COMMON% /UNILOG:%LOG%\W_<Unit>_verify.log

:: ===== Cutover only, Hot only: preview deletions, review *EXTRA lines, then run without /L =====
robocopy "W:\Sistemas\<Unit>" "%HOT%\W_Sistemas\<Unit>" /E /PURGE /L /COPY:DATSO /MT:32 %RC_COMMON% /UNILOG:%LOG%\W_<Unit>_purge_preview.log
```

**Pilot, Gate P (T-3 days).** Choose two real test sets on W: of about 20 GB each: (a) large files (> 100 MB) and (b) folders of small PDFs/XMLs (≥ 50,000 files). Then:

```powershell
$dst = '\\agace-gcp-fs01.agace.local\Hot$\_pilot'
foreach ($t in @(@('large', 'W:\Sistemas\<PilotLarge>'), @('small', 'W:\Sistemas\<PilotSmall>'))) {
  $m = Get-ChildItem -LiteralPath $t[1] -Recurse -File -Force | Measure-Object Length -Sum
  $s = Measure-Command { robocopy $t[1] "$dst\$($t[0])" /E /COPY:DAT /MT:32 /R:2 /W:5 /XJ /NP /NFL /NDL /UNILOG:"C:\AGACE-Migration\logs\pilot_$($t[0]).log" }
  '{0}: {1:N0} files, {2:N2} GB, {3:N0} s => {4:N1} MB/s, {5:N0} files/s' -f $t[0], $m.Count, ($m.Sum/1e9), $s.TotalSeconds, ($m.Sum/1e6/$s.TotalSeconds), ($m.Count/$s.TotalSeconds)
}
Get-SmbConnection | Format-Table ServerName, ShareName, Dialect    # expect 3.x
```

Use the result (`R_eff` from "large", `F_rate` from "small") in Section 5. Repeat once with `/MT:64` and keep the faster setting. Delete `_pilot` on the VM afterwards.

### 2.5 Orchestrator: `04-Run-Robocopy.ps1`

The orchestrator reads `jobs.csv`, runs up to 4 units in parallel (never two on the same physical drive), applies the window, kills units still running 15 minutes after the window ends (they become `Partial` and rerun the next night), and records status and exit code per unit.

Unit states: `Pending → Running → Done → Verified`. `Failed`, `Fatal`, `Partial` and `NotVerified` are picked up again by the next Baseline. `Hold` waits for seeding.

`scripts/04-Run-Robocopy.ps1`

```powershell
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
```

```powershell
.\04-Run-Robocopy.ps1 -Mode Baseline                       # task 01-Baseline (22:00-05:00)
.\04-Run-Robocopy.ps1 -Mode Delta                          # task 02-DailySync (23:59-04:00), Hot units already copied
.\04-Run-Robocopy.ps1 -Mode Verify -Window 0000-2359       # weekend / Gate H & Gate A evidence (/L, copies nothing)
.\04-Run-Robocopy.ps1 -Mode Verify -Reverify -Purge -Tier Hot -Window 0000-2359   # cutover: deletion preview
.\04-Run-Robocopy.ps1 -Mode Delta  -Purge -Window 0000-2359                       # cutover: final sync incl. deletions
Import-Csv C:\AGACE-Migration\jobs\jobs.csv | Group-Object Tier, Status | Select-Object Name, Count
```

### 2.6 Seeding G: duplicates inside GCP

Run this on the day the last W: Cold unit reaches `Done`, before any G: unit is released from `Hold`:

```powershell
# AGACE-FS01
.\02-Find-Duplicates.ps1                      # re-confirm with robocopy /L: data may have changed since the inventory
.\10-Build-SeedScript.ps1
Copy-Item C:\AGACE-Migration\jobs\seed-on-vm.ps1 '\\agace-gcp-fs01.agace.local\ColdStage$\_control\'
# VM (elevated): local disk-to-disk copy, no WAN
powershell -NoProfile -ExecutionPolicy Bypass -File S:\AGACE\Cold\_control\seed-on-vm.ps1
# AGACE-FS01: release the held G: units
$jf = 'C:\AGACE-Migration\jobs\jobs.csv'; $j = Import-Csv $jf
$j | Where-Object Status -eq 'Hold' | ForEach-Object { $_.Status = 'Pending' }; $j | Export-Csv $jf -NoTypeInformation -Encoding UTF8
```

`scripts/10-Build-SeedScript.ps1`

```powershell
#Requires -Version 5.1
# 10-Build-SeedScript.ps1 - runs on the SOURCE server. For every 'Identical' G:<->W: pair it writes a robocopy
# line that clones the already-migrated W: copy INSIDE the VM into the G: destination. The later G: job then
# finds every file "same" (size+timestamp) and sends almost nothing over the WAN, yet G: stays a 1:1 copy.
param(
    [string]$JobsCsv = 'C:\AGACE-Migration\jobs\jobs.csv',
    [string]$DupCsv = 'C:\AGACE-Migration\inventory\duplicates.csv',
    [string]$OutPs1 = 'C:\AGACE-Migration\jobs\seed-on-vm.ps1',
    [string]$RootB = 'W:\Sistemas',
    [string]$RootBDest = 'W_Sistemas',
    [hashtable]$ShareToLocal = @{
        '\\agace-gcp-fs01.agace.local\Hot$'       = 'E:\AGACE\Hot'
        '\\agace-gcp-fs01.agace.local\ColdStage$' = 'S:\AGACE\Cold'
    }
)
$ErrorActionPreference = 'Stop'
function Test-Under([string]$child, [string]$parent) { $child.StartsWith($parent.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) }
function ConvertTo-Local([string]$unc) {
    foreach ($k in $ShareToLocal.Keys) { if ($unc.StartsWith($k, [StringComparison]::OrdinalIgnoreCase)) { return $ShareToLocal[$k] + $unc.Substring($k.Length) } }
    throw "No local mapping for $unc"
}
$jobs = @(Import-Csv $JobsCsv)
$out = New-Object System.Collections.Generic.List[string]
$out.Add('# Generated by 10-Build-SeedScript.ps1 - run on the VM as Administrator AFTER the W: jobs are Done and BEFORE the G: jobs.')
foreach ($d in Import-Csv $DupCsv | Where-Object Verdict -eq 'Identical') {
    $A = $d.PathA
    $B = $d.PathB
    $wJobs = @($jobs | Where-Object { $_.Source -ieq $B -or (Test-Under $_.Source $B) -or ($_.Recurse -eq 'True' -and (Test-Under $B $_.Source)) })
    if ($wJobs.Count -eq 0 -or @($wJobs | Where-Object Tier -ne 'Cold').Count -gt 0) {
        Write-Warning "Skipped $A <-> $B : the W: side is not entirely Cold (static), so seeding could add files that are not on G:."
        continue
    }
    foreach ($g in $jobs) {
        if ($g.AgeSwitch) { continue }
        $rec = $g.Recurse -eq 'True'
        if ($g.Source -ieq $A -or (Test-Under $g.Source $A)) { $aPart = $g.Source }
        elseif ($rec -and (Test-Under $A $g.Source)) { $aPart = $A }
        else { continue }
        $dst = (ConvertTo-Local ($g.Destination + $aPart.Substring($g.Source.Length))).Replace("'", "''")
        $relB = $B.Substring($RootB.TrimEnd('\').Length) + $aPart.Substring($A.Length)
        foreach ($tierRoot in $ShareToLocal.Values) {
            $src = "$tierRoot\$RootBDest$relB".Replace("'", "''")
            $e = if ($rec) { '/E ' } else { '' }
            $out.Add("if (Test-Path -LiteralPath '$src') { robocopy '$src' '$dst' $e/COPY:DAT /DCOPY:DAT /MT:64 /R:1 /W:1 /XJ /NP /NFL /NDL /UNILOG+:E:\AGACE\seed.log }")
        }
    }
}
[System.IO.File]::WriteAllLines($OutPs1, $out, (New-Object System.Text.UTF8Encoding($true)))
Write-Host "$($out.Count - 1) seed commands written to $OutPs1"
```

The script seeds only pairs whose W: side is entirely Cold. A Hot W: folder may have gained files since the inventory, and seeding would plant files that never existed on G:. After the G: jobs run, `Verify` must return exit 0 for the seeded units.

### 2.7 Exit codes and common errors

| Robocopy exit | Meaning | Orchestrator status |
|---|---|---|
| 0 | Nothing to copy (already identical) | Done / Verified |
| 1 | Files copied OK | Done |
| 2 | Extra files at destination (deleted at source after copy) | Done / Verified |
| 3, 5, 6, 7 | Combinations of the above / mismatches | Done (review log) |
| 8–15 | Some files failed after retries | Failed: rerun next night |
| ≥ 16 | Fatal (path, permission or syntax) | Fatal: fix before next night |

| Log error | Cause | Action |
|---|---|---|
| `ERROR 5` Access denied | Not elevated, `/B` without rights | Check the task's RunLevel Highest and Backup Operators membership |
| `ERROR 32` File in use | Open by a user or application | Picked up by the daily sync. DB files go by native backup |
| `ERROR 53` / `ERROR 64` Network name no longer available | VPN or ISP drop | Section 6.2 |
| `ERROR 112` Not enough space | PD full | `gcloud compute disks resize agace-hot --size=<GB> --zone=…`, then `Resize-Partition` on the VM |
| `ERROR 21` Device not ready | USB disk slept or disconnected | Check power settings and the cable. Section 6.3 if it repeats |
| `ERROR 23` CRC / `ERROR 1117` I/O device error | **Source disk is failing** | **STOP that drive now.** Section 6.3 |
| `ERROR 1314` Privilege not held | Setting the owner (O) on the VM | Add the account to Backup Operators on the VM |

```powershell
# Error histogram for last night (language-neutral pattern)
Select-String -Path C:\AGACE-Migration\logs\Baseline\*\*.log -Pattern 'ERROR (\d+) \(0x' |
  ForEach-Object { $_.Matches[0].Groups[1].Value } | Group-Object | Sort-Object Count -Descending | Format-Table Name, Count
```

---

## 3. Google Cloud Storage: buckets, lifecycle and retention

### 3.1 How lifecycle works (and why the design is not "age > 5 years")

* The lifecycle `age` condition counts days since the object was **created in the bucket**, not since the file's LastWriteTime. A 2013 pedimento uploaded in November 2026 has `age = 0`, so a plain "age ≥ 1825 days → Archive" rule would leave all historical data in Standard until 2031.
* The design therefore does three things:
  1. Cold data (2012–2020) goes straight into a bucket whose **default class is ARCHIVE**. There is no transition, no Standard cost and no class-change operations.
  2. Hot objects get a **Custom-Time** equal to the month of the file's LastWriteTime (script 08). The rules use `daysSinceCustomTime`.
  3. `age` rules act as a backstop for objects without Custom-Time, i.e. files created after cutover, where upload date ≈ document date.
* Conditions inside one rule are ANDed, and separate rules are ORed. When several SetStorageClass rules match, GCS applies the one to the cheapest class. Actions can take up to 24 h to apply.
* Minimum storage durations: Nearline 30 days, Coldline 90 days, Archive 365 days. Deleting earlier is billed as if stored for the minimum.
* **Every class returns data in milliseconds.** There is no tape-style restore, so Archive meets the "immediate audit retrieval" requirement. Retrieval has a per-GB fee: roughly US$0.02/GB for Coldline and US$0.05/GB for Archive (list price; verify in the Pricing Calculator for `northamerica-south1`).

| Data | Location | Class | Transitions |
|---|---|---|---|
| Hot (newest file ≥ 2021) | VM E: + `gs://agace-operacion-activa` | STANDARD | → COLDLINE at 5 years (1826 days) of document date → ARCHIVE at 7 years (2557 days) |
| Cold 2012–2020 | `gs://agace-archivo-historico-2012-2020` | ARCHIVE from day 0 | none |
| Previous versions (files overwritten or deleted on the VM) | `gs://agace-operacion-activa` | → COLDLINE after 30 days | deleted 5 years after becoming non-current (**confirm with compliance**) |

Coldline is used for years 5–7 because late audits and extended terms cluster there, and Coldline retrieval costs less than half of Archive's. If AGACE prefers Archive at 5 years, change `COLDLINE` to `ARCHIVE` in the first two rules.

### 3.2 Create the buckets

```bash
gcloud storage buckets create gs://agace-operacion-activa --location=northamerica-south1 \
  --default-storage-class=STANDARD --uniform-bucket-level-access --public-access-prevention
gcloud storage buckets update gs://agace-operacion-activa --versioning
gcloud storage buckets create gs://agace-archivo-historico-2012-2020 --location=northamerica-south1 \
  --default-storage-class=ARCHIVE --uniform-bucket-level-access --public-access-prevention
```

The Hot bucket has **no** retention policy on purpose. A retention policy blocks overwriting or deleting young objects, so the nightly sync of edited files would fail. Versioning plus the non-current rules protect the data instead.

### 3.3 Lifecycle rules (Hot bucket)

`gcp/lifecycle-operacion-activa.json`:

`gcp/lifecycle-operacion-activa.json`

```json
{
  "lifecycle": {
    "rule": [
      {
        "action": { "type": "SetStorageClass", "storageClass": "COLDLINE" },
        "condition": { "daysSinceCustomTime": 1826, "matchesStorageClass": ["STANDARD"], "isLive": true }
      },
      {
        "action": { "type": "SetStorageClass", "storageClass": "COLDLINE" },
        "condition": { "age": 1826, "matchesStorageClass": ["STANDARD"], "isLive": true }
      },
      {
        "action": { "type": "SetStorageClass", "storageClass": "ARCHIVE" },
        "condition": { "daysSinceCustomTime": 2557, "matchesStorageClass": ["STANDARD", "COLDLINE"], "isLive": true }
      },
      {
        "action": { "type": "SetStorageClass", "storageClass": "ARCHIVE" },
        "condition": { "age": 2557, "matchesStorageClass": ["STANDARD", "COLDLINE"], "isLive": true }
      },
      {
        "action": { "type": "SetStorageClass", "storageClass": "COLDLINE" },
        "condition": { "daysSinceNoncurrentTime": 30, "matchesStorageClass": ["STANDARD"], "isLive": false }
      },
      {
        "action": { "type": "Delete" },
        "condition": { "daysSinceNoncurrentTime": 1826, "isLive": false }
      }
    ]
  }
}
```

```bash
gcloud storage buckets update gs://agace-operacion-activa --lifecycle-file=lifecycle-operacion-activa.json
gcloud storage buckets describe gs://agace-operacion-activa      # check lifecycle_config, versioning, default class
gcloud storage buckets describe gs://agace-archivo-historico-2012-2020
```

### 3.4 Retention policy (archive bucket), after Gate A only

```bash
# Only after every Cold unit is uploaded and verified (Gate A). Otherwise a bad upload is frozen for 5 years.
gcloud storage buckets update gs://agace-archivo-historico-2012-2020 --retention-period=1826d
# IRREVERSIBLE. Only with written approval from AGACE management and compliance counsel (A7).
gcloud storage buckets update gs://agace-archivo-historico-2012-2020 --lock-retention-period
```

The retention clock starts per object at upload. Once locked, the period can be increased but never reduced, and the bucket cannot be deleted while it holds protected objects.

### 3.5 IAM, audit logging, security

```bash
SA=sa-agace-fs@agace-migracion.iam.gserviceaccount.com
gcloud storage buckets add-iam-policy-binding gs://agace-operacion-activa --member=serviceAccount:$SA --role=roles/storage.objectAdmin
gcloud storage buckets add-iam-policy-binding gs://agace-archivo-historico-2012-2020 --member=serviceAccount:$SA --role=roles/storage.objectAdmin
# After Gate A: the VM becomes read-only on the archive; auditors get read access
gcloud storage buckets remove-iam-policy-binding gs://agace-archivo-historico-2012-2020 --member=serviceAccount:$SA --role=roles/storage.objectAdmin
gcloud storage buckets add-iam-policy-binding gs://agace-archivo-historico-2012-2020 --member=serviceAccount:$SA --role=roles/storage.objectViewer
gcloud storage buckets add-iam-policy-binding gs://agace-archivo-historico-2012-2020 --member=group:auditoria@agace.com.mx --role=roles/storage.objectViewer
```

* Enable Data Access audit logs for Cloud Storage (Data Read and Data Write) under IAM & Admin → Audit Logs. Every audit download is then recorded.
* The VM has no public IP. RDP goes only through IAP, SMB 445 is open only to AGACE-FS01, and both buckets enforce Public Access Prevention.
* Before UploadCold, run one malware scan of the staging disk: `Start-MpScan -ScanType CustomScan -ScanPath S:\AGACE\Cold`. Nothing infected should go into an immutable archive. Real-time scanning of `E:\AGACE` and `S:\AGACE` may be paused during the baseline only with security sign-off, and must be re-enabled at cutover.

### 3.6 Loading the buckets from the VM

`scripts/07-VM-Gcs.ps1`

```powershell
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
```

```powershell
pwsh -File E:\AGACE\scripts\07-VM-Gcs.ps1 -Mode SyncHot       # nightly 05:30 (task VM-SyncHot)
pwsh -File E:\AGACE\scripts\07-VM-Gcs.ps1 -Mode UploadCold    # daily 06:00, Verified cold units only
pwsh -File E:\AGACE\scripts\07-VM-Gcs.ps1 -Mode Verify        # evidence for Gate H / Gate A
```

`gcloud storage` validates checksums on upload. In `Verify` output, Cold must show `Match = True` for every folder. For Hot, `GcsObjects ≥ LocalFiles` is expected, because deleted and renamed files remain in the bucket by design.

GCS object names are limited to 1,024 bytes (UTF-8). Check this before the first upload:

```powershell
Get-ChildItem E:\AGACE\Hot, S:\AGACE\Cold -Recurse -File -Force | Where-Object { [Text.Encoding]::UTF8.GetByteCount($_.FullName) -gt 1000 } | Select-Object FullName
```

**Custom-Time stamping (once, at Gate H, after the first complete SyncHot):**

`scripts/08-VM-Stamp-CustomTime.ps1`

```powershell
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
```

```powershell
# 1) Encoding test with ONE accented name (use a recent date so the object does not change class)
New-Item -ItemType Directory E:\AGACE\Hot\_prueba -Force | Out-Null
Set-Content -LiteralPath 'E:\AGACE\Hot\_prueba\Pedimento_Año_Señal.txt' -Value 'test'
pwsh -File E:\AGACE\scripts\07-VM-Gcs.ps1 -Mode SyncHot
'gs://agace-operacion-activa/_prueba/Pedimento_Año_Señal.txt' | Set-Content E:\AGACE\ct-test.txt -Encoding utf8NoBOM
$env:PYTHONUTF8 = '1'; cmd /c "gcloud storage objects update --read-paths-from-stdin --custom-time=2025-01-01T00:00:00Z < E:\AGACE\ct-test.txt"
gcloud storage objects describe "gs://agace-operacion-activa/_prueba/Pedimento_Año_Señal.txt"   # custom_time must be set
# 2) Dry run, then real run
pwsh -File E:\AGACE\scripts\08-VM-Stamp-CustomTime.ps1 -WhatIf
pwsh -File E:\AGACE\scripts\08-VM-Stamp-CustomTime.ps1
```

After stamping, objects whose document month is more than 5 years old move to COLDLINE (and more than 7 years old to ARCHIVE) within about 24 h. That is the policy working as intended. Names containing `* ? [ ]` cannot be stamped through wildcard URLs. They are listed in `skipped-wildcard-names.txt` and fall back to the `age` rules.

### 3.7 Audit retrieval procedure (SAT / ANAM request)

1. Locate the file. The manifests (`summary_folders.csv`, `files_*.tsv`, `jobs.csv`, `duplicates.csv`, zipped robocopy logs) are uploaded at Gate A to `gs://agace-archivo-historico-2012-2020/_manifest/`, where they are covered by the same retention.
2. Search by pedimento number or client and copy the folder to an audit folder on the VM, which stays inside GCP so there is no egress charge:

```powershell
gcloud storage ls "gs://agace-archivo-historico-2012-2020/W_Sistemas/**/*3001234*"
gcloud storage cp --recursive "gs://agace-archivo-historico-2012-2020/W_Sistemas/<path>" "E:\AGACE\Auditoria\SAT-2026-001\"
```

3. A 10 GB expediente is available in minutes and costs about US$0.50 in Archive retrieval. Internet/VPN egress pricing applies only if the files are downloaded outside GCP. Auditors with `objectViewer` can also download from the Cloud Console.

### 3.8 Cost model (illustrative; replace with the 1.5 totals and current regional prices)

| Item | Example size | Approx. list price / GB-month | Monthly |
|---|---|---|---|
| VM disk `agace-hot` (pd-balanced) | 5,200 GB | US$0.10 | ≈ US$520 |
| Bucket activa (Standard) | 4,000 GB | US$0.020 | ≈ US$80 |
| Bucket histórico (Archive) | 7,000 GB | US$0.0012 | ≈ US$8 |
| *Comparison: the same 7 TB of Cold on pd-balanced* | 7,000 GB | US$0.10 | *≈ US$700* |
| Temporary `agace-cold-staging` (pd-standard), until Gate A | 8,000 GB | US$0.04 | ≈ US$320, pro-rated |

Most of the saving comes from keeping Cold data off VM disks. GCS class optimisation is a second-order effect.

---

## 4. Windows Task Scheduler: nightly multi-drive sync

### 4.1 Service account

`AGACE\svc-migration` (or a gMSA) needs, for the duration of the migration only:

* local Administrators on AGACE-FS01, because `/B`, RunLevel Highest and event-log writes require it;
* Backup Operators on the VM, and Full Control on the `Hot$` and `ColdStage$` shares;
* "Log on as a batch job".

Remove these rights after cutover plus 30 days.

### 4.2 Nightly timeline

| Time (Matamoros) | Host | Task | Behavior |
|---|---|---|---|
| 21:55 | FS01 | `\AGACE\03-Monitor` | Samples NIC bytes every 60 s until 05:05; writes the projection at the end |
| 22:00 | FS01 | `\AGACE\01-Baseline` | Pending/Failed/Partial units; no new file after 05:00; kills at 05:15; task limit 7 h 30 min |
| 23:59 | FS01 | `\AGACE\02-DailySync` | Daily-work sync of Hot units already copied (max 2 in parallel); no new file after 04:00; kills at 04:15 |
| 05:30 | VM | `\AGACE\VM-SyncHot` | E: → Hot bucket (inside GCP, no WAN) |
| 06:00 | VM | `\AGACE\VM-UploadCold` | Verified Cold units → archive bucket |
| 06:00 | GCP | Snapshot `agace-daily-0600` | `agace-hot` disk, 14 days |
| 07:30 | Ops | Morning check | Section 5.5 |

The 23:59–04:00 daily sync runs **inside** the 22:00–05:00 baseline window, and both share the uplink. Pausing the baseline during the sync would leave only ~3 h per night for baseline, which makes 11.2 TB impossible (5.3). That is why they run concurrently.

Task settings that matter:

* `Priority 4`: the default of 7 gives below-normal CPU *and* low I/O priority and visibly slows robocopy.
* `MultipleInstances IgnoreNew`.
* `StartWhenAvailable` left off, so a missed night never starts at 09:00 during business hours.

### 4.3 Register the source-server tasks

`scripts/06-Register-Tasks.ps1`

```powershell
#Requires -Version 5.1
#Requires -RunAsAdministrator
# 06-Register-Tasks.ps1 - registers the nightly tasks on the SOURCE server (Task Scheduler folder \AGACE\).
param(
    [string]$ScriptDir = 'C:\AGACE-Migration\scripts',
    [string]$RunAs = 'AGACE\svc-migration',
    [datetime]$FirstNight = '2026-11-23',
    [int]$BaselineNights = 10,
    [int]$BufferNights = 2,
    [datetime]$CutoverDate = '2026-12-05'
)
$ErrorActionPreference = 'Stop'
$cred = Get-Credential -UserName $RunAs -Message 'Password for the migration service account'
if (-not [System.Diagnostics.EventLog]::SourceExists('AGACE-Migration')) { New-EventLog -LogName Application -Source 'AGACE-Migration' }
$ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

function Register-AgaceTask([string]$name, [string]$hhmm, [string]$arguments, [timespan]$limit, [datetime]$until) {
    $action = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -ExecutionPolicy Bypass -File $arguments" -WorkingDirectory $ScriptDir
    $trigger = New-ScheduledTaskTrigger -Daily -At $FirstNight.Date.Add([timespan]::Parse($hhmm))
    $trigger.EndBoundary = $until.ToString('yyyy-MM-ddTHH:mm:ss')
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit $limit -MultipleInstances IgnoreNew -Priority 4 `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $name -TaskPath '\AGACE\' -Action $action -Trigger $trigger -Settings $settings `
        -User $cred.UserName -Password $cred.GetNetworkCredential().Password -RunLevel Highest -Force | Out-Null
    Write-Host "Registered \AGACE\$name daily at $hhmm until $until"
}
$baselineEnd = $FirstNight.Date.AddDays($BaselineNights + $BufferNights).AddHours(6)
Register-AgaceTask '01-Baseline' '22:00' "`"$ScriptDir\04-Run-Robocopy.ps1`" -Mode Baseline -Window 2200-0500" (New-TimeSpan -Hours 7 -Minutes 30) $baselineEnd
Register-AgaceTask '02-DailySync' '23:59' "`"$ScriptDir\04-Run-Robocopy.ps1`" -Mode Delta -Window 2359-0400 -MaxParallel 2" (New-TimeSpan -Hours 4 -Minutes 30) $CutoverDate.Date.AddHours(6)
Register-AgaceTask '03-Monitor' '21:55' "`"$ScriptDir\05-Monitor-Bandwidth.ps1`" -Window 2155-0505" (New-TimeSpan -Hours 7 -Minutes 30) $baselineEnd
Get-ScheduledTask -TaskPath '\AGACE\' | Get-ScheduledTaskInfo | Format-Table TaskName, NextRunTime, LastRunTime, LastTaskResult -AutoSize
```

```powershell
Set-Location C:\AGACE-Migration\scripts
.\06-Register-Tasks.ps1 -RunAs 'AGACE\svc-migration' -FirstNight '2026-11-23' -BaselineNights 10 -CutoverDate '2026-12-05'
schtasks /query /tn "\AGACE\01-Baseline" /v /fo LIST
# Smoke test outside the window: must finish in ~15 s with "0 units run" (it never copies outside the window)
Start-ScheduledTask -TaskPath '\AGACE\' -TaskName '01-Baseline'
Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='AGACE-Migration'} -MaxEvents 5 | Format-List TimeCreated, Id, Message
```

### 4.4 Optional bandwidth cap (QoS) to protect night operations

If the same uplink carries night-shift traffic (VUCEM, pedimento validation, VoIP), cap robocopy instead of using `/IPG`:

```powershell
New-NetQosPolicy -Name 'AGACE-Robocopy-Cap' -AppPathNameMatchCondition 'robocopy.exe' -ThrottleRateActionBitsPerSecond 400000000   # 400 Mbps
Get-NetQosPolicy -Name 'AGACE-Robocopy-Cap'
Remove-NetQosPolicy -Name 'AGACE-Robocopy-Cap' -Confirm:$false      # when no longer needed
```

### 4.5 VM tasks

```powershell
$pw  = 'C:\Program Files\PowerShell\7\pwsh.exe'
$set = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 12) -MultipleInstances IgnoreNew -Priority 4
$a1  = New-ScheduledTaskAction -Execute $pw -Argument '-NoProfile -File E:\AGACE\scripts\07-VM-Gcs.ps1 -Mode SyncHot'
$a2  = New-ScheduledTaskAction -Execute $pw -Argument '-NoProfile -File E:\AGACE\scripts\07-VM-Gcs.ps1 -Mode UploadCold'
Register-ScheduledTask -TaskPath '\AGACE\' -TaskName 'VM-SyncHot'    -Action $a1 -Trigger (New-ScheduledTaskTrigger -Daily -At 05:30) -Settings $set -User 'NT AUTHORITY\SYSTEM' -RunLevel Highest
Register-ScheduledTask -TaskPath '\AGACE\' -TaskName 'VM-UploadCold' -Action $a2 -Trigger (New-ScheduledTaskTrigger -Daily -At 06:00) -Settings $set -User 'NT AUTHORITY\SYSTEM' -RunLevel Highest
```

SYSTEM authenticates to GCS with the VM service account through the metadata server. If the `hot-*.log` shows "Permission denied" on files whose copied ACLs exclude SYSTEM, grant read on the destination copy only: `icacls E:\AGACE\Hot /grant "SYSTEM:(OI)(CI)RX" /T /C`.

### 4.6 After cutover

```powershell
Get-ScheduledTask -TaskPath '\AGACE\' | Disable-ScheduledTask        # on AGACE-FS01
# On the VM keep VM-SyncHot permanently; move it to 01:00 now that users work on the VM
Set-ScheduledTask -TaskPath '\AGACE\' -TaskName 'VM-SyncHot' -Trigger (New-ScheduledTaskTrigger -Daily -At 01:00)
Disable-ScheduledTask -TaskPath '\AGACE\' -TaskName 'VM-UploadCold'  # after Gate A
```

---

## 5. Verification gates and bandwidth math

### 5.1 Units

Windows Explorer labels sizes "TB" but means **TiB** (2⁴⁰ bytes). **11.2 "TB" = 11.2 TiB = 12.31 TB decimal = 12,314,530 MB.** Link speeds are decimal. 1 MB/s = 8 Mbps. All formulas below use decimal MB.

### 5.2 Formulas

| Symbol | Definition |
|---|---|
| `D_wan` | Bytes that must cross the WAN = Hot TB + Cold TB (from 1.5) − `D_dup` (seeded duplicates, 1.4) |
| `N` | Number of files to transfer (from `summary_folders.csv`) |
| `η` | Protocol efficiency (IPsec + TCP + SMB3), 0.75–0.85; measure in the pilot |
| `R_eff` | Effective throughput (MB/s) = `L_Mbps × η / 8`, or measured directly in the pilot "large" test |
| `F_rate` | Files per second measured in the pilot "small" test (bound by latency, threads and disk) |
| `W` | Window hours per night (baseline = 7) |
| `U` | Window utilisation = 0.9 (job start-up, tail, file in flight at 05:00) |

```
Transfer time (conservative)      T  = D_wan / R_eff  +  N / F_rate                       [s]
Capacity per night                C  = R_eff × W × 3600 × U                               [MB/night]
Nights needed                     Nn = T / (W × 3600 × U)
Throughput required for 10 nights R_req = D_wan / (10 × W × 3600 × U)                     [MB/s]
Link required                     L_req = R_req × 8 / η                                   [Mbps]
Daily-sync fit (Hot only)         T_delta = N_hot / S_scan + ΔD_day / R_eff  ≤  4.0 h × 0.85
   S_scan = files/s from a Verify (/L) run over Hot units; ΔD_day = bytes changed per day
```

### 5.3 Worked example: full 11.2 TiB, no deduplication (worst case)

* Seconds available: `10 × 7 × 3600 × 0.9 = 226,800 s`
* `R_req = 12,314,530 MB / 226,800 s = 54.3 MB/s = 434 Mbps sustained`
* With η = 0.8: **`L_req ≈ 543 Mbps`** of dedicated night-time bandwidth.
* If the baseline paused during the 23:59–04:00 sync, only ~2.98 h/night would remain: `R_req = 127.4 MB/s ≈ 1,019 Mbps` sustained (≈ 1.27 Gbps link). That is not achievable on a 1 Gbps line, hence the concurrent design.

| Uplink (Mbps) | R_eff @ η 0.8 (MB/s) | TB per night (7 h, U 0.9) | Nights for 11.2 TiB | Nights for 8.2 TiB (if 3 TiB dedup) | Nights for 4 TB Hot only |
|---|---|---|---|---|---|
| 100 | 10 | 0.23 | 54.3 | 39.8 | 17.6 |
| 200 | 20 | 0.45 | 27.1 | 19.9 | 8.8 |
| 300 | 30 | 0.68 | 18.1 | 13.3 | 5.9 |
| 500 | 50 | 1.13 | 10.9 | 8.0 | 3.5 |
| 750 | 75 | 1.70 | 7.2 | 5.3 | 2.4 |
| 1000 | 100 | 2.27 | 5.4 | 4.0 | 1.8 |

Add the small-file term. Example: 3,000,000 files at a measured 150 files/s gives `3e6 / 150 = 20,000 s ≈ 5.6 h` (≈ 0.9 nights) on top of the byte time.

**What this means for AGACE:**

* Below ~550 Mbps sustained, the whole 11.2 TB will not finish in 10 nights.
* With 300 Mbps, the Hot tier alone (example: 4 TB) finishes in ~6 nights. Cutover can proceed on schedule, and Cold keeps loading on the following nights with no impact on FM2.
* Removing duplicates and C: OS data shrinks `D_wan` directly.

### 5.4 Gate P: pilot result vs plan

Record `R_eff`, `F_rate`, the SMB dialect and the RTT (`Test-NetConnection agace-gcp-fs01.agace.local -Port 445` plus `ping`). Compute `Nn` with the real Hot/Cold totals.

* `Nn(all) ≤ 9`: GO with the full plan.
* `Nn(Hot) ≤ 9` but `Nn(all) > 9`: GO with "Hot-first, Cold after cutover". Tell management the new Cold completion date.
* `Nn(Hot) > 9`: NO-GO. Upgrade bandwidth temporarily, add weekend daytime windows (Sat 14:00 – Mon 05:00, if AGACE is closed), or reduce scope.

### 5.5 Nightly monitoring

`scripts/05-Monitor-Bandwidth.ps1`

```powershell
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
```

Morning check (07:30, ~10 minutes):

```powershell
Import-Csv C:\AGACE-Migration\monitor\projection.csv | Select-Object -Last 1 | Format-List
Import-Csv C:\AGACE-Migration\jobs\jobs.csv | Group-Object Tier, Status | Select-Object Name, Count
Get-ChildItem C:\AGACE-Migration\logs\Baseline | Sort-Object Name | Select-Object -Last 1 | ForEach-Object { Import-Csv "$($_.FullName)\summary.csv" } | Where-Object Status -ne 'Done' | Format-Table
Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='AGACE-Migration'; StartTime=(Get-Date).AddHours(-12)} | Format-Table TimeCreated, Id, LevelDisplayName -AutoSize
# On the VM: free space
Get-Volume -DriveLetter E, S | Format-Table DriveLetter, @{n='FreeGB';e={[math]::Round($_.SizeRemaining/1GB)}}, @{n='SizeGB';e={[math]::Round($_.Size/1GB)}}
```

| Status (projection) | Rule | Action |
|---|---|---|
| GREEN | `NightsNeededAll ≤ NightsLeft − 1` | Continue |
| AMBER | Only Hot fits (`NightsNeededHot ≤ NightsLeft − 1`) | Run Hot-first: `-Tier Hot` on Baseline tonight. Cold continues after cutover |
| RED | Hot does not fit | Escalate the same day: Section 6.2 levers, change the cutover date |
| Event 1101 | < 70 % of planned MB/s for 30 min | Section 6.2 |

The NIC counter measures all traffic the server sends. Nights are normally quiet. If an off-site backup also runs at night, reschedule it during the migration.

### 5.6 Gates

| Gate | When | Pass criteria | Evidence |
|---|---|---|---|
| G0 Pre-flight | T-7 | Disks healthy, power settings applied, VPN up, VM joined, shares reachable from FS01 | 1.1 output, `Test-NetConnection … -Port 445` = True |
| G1 Inventory | T-5 | No `Review` rows; C: allow-list, Hot/Cold totals, Exclude list and DB/PST list approved | Signed `summary_folders.csv`, `jobs.csv` |
| GP Pilot | T-3 | Projection per 5.4 = GO | Pilot output, calculation sheet |
| GN Nightly (N1…N10) | 07:30 daily | No `Fatal`; `Failed` < 1 % of units; projection GREEN/AMBER | `summary.csv`, `projection.csv`, events |
| GH Hot complete | Before cutover | All Hot units `Verified` (exit 0/2); hash sample = no differences for ≥ 1 unit per drive; daily-sync `T_delta` fits; SyncHot + Custom-Time done | Verify logs, `09-Hash-Sample` CSVs, 07 Verify CSV |
| GC Cutover | Sat 12-05 | Purge preview reviewed; final Delta exit < 8; FM2 user acceptance test over VPN (open, save, search) OK; DFS/drive mappings switched | Sign-off sheet |
| GA Archive | After Cold upload | All Cold `Verified`; malware scan clean; 07 `Verify` Cold `Match=True` for every folder; manifests uploaded → retention policy applied → staging disk deleted | 07 Verify CSV, `gcloud storage buckets describe` |

Hash sample per drive (source first, then the VM with the same list):

```powershell
# AGACE-FS01
.\09-Hash-Sample.ps1 -Root 'W:\Sistemas\<Unit>' -OutCsv C:\AGACE-Migration\logs\hash_W_src.csv
Copy-Item C:\AGACE-Migration\logs\hash_W_src.csv '\\agace-gcp-fs01.agace.local\ColdStage$\_control\'
# VM (local disk read, no WAN)
powershell -File E:\AGACE\scripts\09-Hash-Sample.ps1 -Root 'E:\AGACE\Hot\W_Sistemas\<Unit>' -SampleFrom S:\AGACE\Cold\_control\hash_W_src.csv -OutCsv S:\AGACE\Cold\_control\hash_W_dst.csv
# Either host
Compare-Object (Import-Csv hash_W_src.csv) (Import-Csv hash_W_dst.csv) -Property RelPath, SHA256    # no output = PASS
```

### 5.7 Night plan template (adjust with real numbers after Gate P)

| Night | Planned scope | Planned TB | Actual TB | Cumulative | Status |
|---|---|---|---|---|---|
| N1 Mon 11-23 | D: + C: allow-list (validates the pipeline), then W: Hot | | | | |
| N2–N4 | W: Hot, F: Hot, G: Hot (parallel, one job per drive) | | | | |
| N5 | Remaining Hot; daily sync now covers most Hot units | | | | |
| N6 | Verify Hot (weekend daytime run) → Gate H; W: Cold | | | | |
| N7–N9 | W: Cold, F: Cold; seeding (2.6); G: Cold | | | | |
| N10 Wed 12-02 | Remaining Cold, retries | | | | |
| Buffer Thu–Fri | Failed/Partial units, final Verify | | | | |
| Sat 12-05 | Cutover (Gate C) | | | | |

---

## 6. Rollback and contingency

### 6.1 Principles

* The source is read-only to the migration: robocopy never deletes or moves anything on AGACE-FS01. **Before cutover, rollback = stop the tasks.** Users keep working on the source as usual.
* Every unit is idempotent. A rerun copies only what differs, so any failure is recovered by running the same unit again.
* The source stays intact and read-only for **90 days after cutover**. No drive is wiped or repurposed before then, and never before Gate A.
* Use a DFS Namespace (`\\agace.local\Datos`) or GPO drive maps so that cutover and rollback are a target switch, not a change on every PC.

### 6.2 Scenario A: network throttling, ISP or VPN failure

| Symptom | Detection | Action |
|---|---|---|
| Throughput < 70 % of plan for 30 min | Event 1101, `bw_*.csv` | Check both VPN tunnels (`gcloud compute vpn-tunnels describe …`), the firewall CPU and the ISP. Run `ping -l 1372 -f 10.50.0.10` to rule out MTU/fragmentation problems |
| Tunnel drops (`ERROR 64/53` in many units) | Units end `Failed` | Nothing to roll back. Units rerun the next night, and HA VPN fails over to the second tunnel |
| ISP fair-use throttling after X TB | Steady decline night after night | Ask the ISP for a temporary uncapped plan; add weekend daytime windows |
| Projection AMBER | `projection.csv` | `-Tier Hot` until Gate H; Cold continues after cutover (no business impact) |
| Projection RED | `projection.csv` | Management decision the same day: move the cutover date, temporary bandwidth, or a physical transfer of the Cold tier (Google Transfer Appliance: check availability in Mexico; lead time is weeks, so it is a Cold-tier fallback only) |
| Saturation hurts daytime work | User complaints | Tasks never start outside their windows. Apply the 4.4 QoS cap |

### 6.3 Scenario B: a source drive fails mid-migration (most likely F: or G:, USB)

1. **Stop reading the drive immediately.** Every extra read hurts a failing disk. Disable the tasks, kill robocopy, and mark that drive's units `Hold`:

```powershell
Disable-ScheduledTask -TaskPath '\AGACE\' -TaskName '01-Baseline'; Disable-ScheduledTask -TaskPath '\AGACE\' -TaskName '02-DailySync'
Get-Process robocopy -ErrorAction SilentlyContinue | Stop-Process -Force
$jf = 'C:\AGACE-Migration\jobs\jobs.csv'; $j = Import-Csv $jf
$j | Where-Object { $_.Source -like 'G:\*' -and $_.Status -notin 'Done', 'Verified' } | ForEach-Object { $_.Status = 'Hold' }
$j | Export-Csv $jf -NoTypeInformation -Encoding UTF8
Enable-ScheduledTask -TaskPath '\AGACE\' -TaskName '01-Baseline'; Enable-ScheduledTask -TaskPath '\AGACE\' -TaskName '02-DailySync'   # other drives continue
```

2. **Do not run `chkdsk /f`** on a failing disk, because it can destroy data. Take a sector-level image or clone first (e.g. `ddrescue` from a Linux boot disk onto a new disk ≥ the original's size, or a professional recovery service if there are mechanical noises).
3. Work out what is already safe:
   * units `Done`/`Verified` (already on the VM);
   * units covered by `duplicates.csv` (the same data exists on W:);
   * whatever is left is the real exposure.
4. Mount the clone under the **same drive letter** and set the `Hold` units back to `Pending`. Robocopy skips everything that is already identical and continues.
5. Document the files that could not be recovered: the `ERROR 23/1117` lines in the logs give the exact paths. AGACE compliance must review this list (records-retention impact).

If an internal drive (D:/W:) fails, the procedure is the same. Restore from the latest backup to a new volume with the same letter first.

### 6.4 Scenario C: destination problem

| Problem | Action |
|---|---|
| VM or Hot disk corrupted or lost | Restore `agace-hot` from the latest snapshot (`agace-daily-0600`). The next Baseline/Delta brings it back in line with the source (idempotent) |
| Staging disk lost before Gate A | Recreate it; set the affected Cold units to `Pending`; copy again (the source is intact) |
| Bad objects in the archive bucket **before** the retention policy | Delete and re-upload (that is why the policy is applied only at Gate A) |
| Accidental deletion or overwrite in the Hot bucket | Restore the previous version (`gcloud storage ls -a`, then `gcloud storage cp gs://…#<generation> …`), or use soft delete (7 days by default) |

### 6.5 Scenario D: cutover rollback (Sat 12-05 … Mon 12-07 08:00)

Trigger: the FM2 acceptance test fails, performance over VPN is unacceptable, or more than 1 % of files are inaccessible.

1. Switch the DFS targets or GPO drive maps back to AGACE-FS01. Re-enable the source shares as read-write.
2. Copy back anything users created on the VM after cutover, newer files only, nothing deleted:

```bat
robocopy "E:\AGACE\Hot\W_Sistemas" "\\AGACE-FS01\W$\Sistemas" /E /XO /COPY:DATSO /DCOPY:DAT /B /MT:32 /R:2 /W:5 /XJ /UNILOG:E:\AGACE\rollback_W.log
```

3. Repeat for each drive folder (`C_Datos`, `D_Informacion`, `F_Lacie`, `G_Seagate`). Re-enable the `02-DailySync` task for the next attempt and record the root cause.

### 6.6 Decision matrix

| Event | Who decides | Max decision time | Default action |
|---|---|---|---|
| Event 1101 / AMBER | Migration engineer | Same morning | Hot-first |
| RED projection | AGACE management + engineer | Same day | Move cutover |
| Drive I/O errors (23/1117) | Engineer, then AGACE IT | Immediate | Stop the drive, image it (6.3) |
| Gate C failure | AGACE management | Before Mon 08:00 | Rollback (6.5) |
| Retention lock | AGACE management + compliance counsel | No deadline | Do not lock without written approval |

---

## 7. Final checklist

| # | Phase | Item | Owner | Gate | Done |
|---|---|---|---|---|---|
| 1 | Prep | Legal confirmation of cutoff (2021-01-01), 5-year clock, lock period (A7) | AGACE compliance | G1 | ☐ |
| 2 | Prep | Confirm AD domain, source OS, FM2/DB architecture, ISP bandwidth (A1–A5) | AGACE IT | G0 | ☐ |
| 3 | Prep | SMART/health of F:, G:; USB power settings; Windows Update paused | AGACE IT | G0 | ☐ |
| 4 | GCP | VPC, HA VPN (MSS 1360), firewall 445/IAP, VM, disks, snapshot schedule | Engineer | G0 | ☐ |
| 5 | GCP | VM: time zone = source, LongPaths, domain join, E:/S:, shares, PowerShell 7, gcloud | Engineer | G0 | ☐ |
| 6 | GCP | Buckets created (activa Standard + versioning; histórico Archive), PAP, UBLA | Engineer | G0 | ☐ |
| 7 | GCP | Lifecycle JSON applied and verified (`describe`) | Engineer | G0 | ☐ |
| 8 | GCP | IAM bindings; Data Access audit logs enabled | Engineer | G0 | ☐ |
| 9 | Inventory | C: allow-list approved (`C_candidates.csv`) | AGACE IT | G1 | ☐ |
| 10 | Inventory | DB/PST list reviewed, native backup plan for live databases | AGACE IT | G1 | ☐ |
| 11 | Inventory | `01-Inventory` run; all `Review` resolved; Hot/Cold TB recorded | Engineer + AGACE | G1 | ☐ |
| 12 | Inventory | G:↔W: duplicates: L1/L2/L3 done; Strategy A/B decided in writing | Engineer + AGACE | G1 | ☐ |
| 13 | Inventory | `jobs.csv` built; G: duplicate units on `Hold` | Engineer | G1 | ☐ |
| 14 | Pilot | Large/small pilot; R_eff, F_rate, SMB dialect, RTT recorded; GO/NO-GO | Engineer | GP | ☐ |
| 15 | Schedule | `06-Register-Tasks` run; smoke test "0 units run"; event source OK | Engineer | GP | ☐ |
| 16 | Schedule | VM tasks VM-SyncHot / VM-UploadCold registered | Engineer | GP | ☐ |
| 17 | Execution | N1–N10 morning checks logged (projection, Failed/Fatal, free space) | Engineer | GN | ☐ |
| 18 | Execution | Seeding script run on VM; G: units released | Engineer | GN | ☐ |
| 19 | Verify | All Hot `Verified`; hash samples PASS per drive; delta fits window | Engineer | GH | ☐ |
| 20 | Verify | SyncHot complete; Custom-Time test + stamping done | Engineer | GH | ☐ |
| 21 | Cutover | Purge preview reviewed; final Delta; FM2 UAT; DFS/drive maps switched | Engineer + AGACE | GC | ☐ |
| 22 | Cutover | Source shares set read-only; source tasks disabled; VM-SyncHot moved to 01:00 | AGACE IT | GC | ☐ |
| 23 | Archive | All Cold `Verified`; malware scan; UploadCold; 07 Verify `Match=True` | Engineer | GA | ☐ |
| 24 | Archive | Manifests + logs to `_manifest/`; retention 1826 d applied | Engineer | GA | ☐ |
| 25 | Archive | Written approval → `--lock-retention-period` (irreversible) | AGACE management + compliance | GA | ☐ |
| 26 | Close | VM SA → objectViewer on archive; staging disk deleted; migration rights removed | Engineer | GA | ☐ |
| 27 | Close | Source kept read-only 90 days; decommission approval | AGACE management | – | ☐ |

## Appendix A: delivered files

| File | Runs on | Purpose |
|---|---|---|
| `scripts/00-Discover-C.ps1` | FS01 | C: business-folder discovery |
| `scripts/01-Inventory.ps1` | FS01 | Inventory and Hot/Cold classification |
| `scripts/02-Find-Duplicates.ps1` | FS01 | G:↔W: duplicate detection (signature + robocopy /L) |
| `scripts/03-Build-Jobs.ps1` | FS01 | Build `jobs.csv` from the approved classification |
| `scripts/04-Run-Robocopy.ps1` | FS01 | Baseline / daily sync / verify orchestrator |
| `scripts/05-Monitor-Bandwidth.ps1` | FS01 | Throughput sampling and completion projection |
| `scripts/06-Register-Tasks.ps1` | FS01 | Task Scheduler registration |
| `scripts/07-VM-Gcs.ps1` | VM | Hot sync, Cold upload, GCS verification |
| `scripts/08-VM-Stamp-CustomTime.ps1` | VM | Custom-Time = document month for lifecycle |
| `scripts/09-Hash-Sample.ps1` | FS01 + VM | SHA-256 sample verification |
| `scripts/10-Build-SeedScript.ps1` | FS01 → VM | Duplicate seeding inside GCP |
| `gcp/lifecycle-operacion-activa.json` | Cloud Shell | Lifecycle rules for the Hot bucket |
