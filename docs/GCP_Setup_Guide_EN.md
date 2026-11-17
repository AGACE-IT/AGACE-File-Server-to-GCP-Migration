# AGACE: Google Cloud Setup Guide (step by step)

This guide builds everything in Google Cloud that must exist **before** any file is copied from the AGACE server (AGACE-FS01). It covers runbook Gate G0, items 4–8 of the checklist in Section 7.

Each step tells you **where** to do it, **what to paste**, and **what you should see**. If what you see is different, stop and send a screenshot or the text output. Do not improvise; nearly everything here can be undone, but a few things cost money while they exist.

| Icon | Where you do it |
|---|---|
| 🌐 | Google Cloud website (console.cloud.google.com), by clicking |
| ⌨️ | **Cloud Shell**: the black terminal inside the Google Cloud website (Part C). Paste commands there. |
| 🖥️ | **The new Google Cloud Windows server** (agace-gcp-fs01), through Remote Desktop (Part I) |
| 🏢 | **The AGACE server** (AGACE-FS01) in Matamoros, or the AGACE office firewall |
| 💻 | **Your Mac** (Terminal app) |

**Never paste into chat, email or the repository:** the VPN shared secret, the Windows password or any Google password. Everything else (command output, IPs, error messages) is safe to share for troubleshooting.

---

## What the replica means for this setup

AGACE keeps working on AGACE-FS01 for **6–18 months**. During that time the Google Cloud side is a **copy that is refreshed every night**, plus a daily backup with history:

```
AGACE-FS01 (users keep working here)
   │  every night 11:59 PM–4:00 AM: robocopy copies new and changed files (never deletes)
   ▼
agace-gcp-fs01 (Google Cloud Windows server)   ── 6:00 AM daily disk snapshot (14 days of restore points)
   │  E: = active data, same folder structure as D:\Informacion, F:\Lacie, G:\Seagate, W:\Sistemas
   │  every morning 5:30 AM
   ▼
Bucket "operacion-activa" (versioned: every changed or deleted file keeps its old versions)
Bucket "archivo-historico-2012-2020" (Archive class: 2012–2020 files, cheapest storage)
```

The setup below is the same whether the server ends up holding **only active data** (runbook design) or **everything, including 2012–2020** ("full replica"). That decision is made after tonight's inventory. The only difference is the size of one disk and whether it is kept (Part H.4).

---

## Part A: Information to collect from the AGACE server (🏢, 10 minutes, read-only)

You don't need this for Parts B–I. You need it for the VPN (Part J). Ask AGACE IT to run this on AGACE-FS01, or run it yourself during tonight's inventory session. Open **PowerShell** (right-click → *Run as administrator*) and paste:

```powershell
hostname
Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } | Format-Table InterfaceAlias, IPAddress, PrefixLength
Get-NetIPConfiguration | Format-List InterfaceAlias, IPv4DefaultGateway, DNSServer
(Get-CimInstance Win32_ComputerSystem) | Format-List Domain, PartOfDomain
(Get-CimInstance Win32_OperatingSystem).Caption
$PSVersionTable.PSVersion
tzutil /g
Get-SmbShare | Where-Object { $_.Name -notlike '*$' } | Format-Table Name, Path
Invoke-RestMethod -Uri 'https://api.ipify.org'
```

Write the answers in this table (and in `Decisions.md` where noted):

| What | Where it shows up in the output | Example | Your value |
|---|---|---|---|
| Server IP (`SOURCE_IP`) | `IPAddress` | 192.168.10.20 | |
| Office network (`ONPREM_LAN`) | `IPAddress` + `PrefixLength`. A /24 means replace the last number with 0. | 192.168.10.0/24 | |
| Firewall/router IP | `IPv4DefaultGateway` | 192.168.10.1 | |
| DNS server(s), usually the domain controller | `DNSServer` | 192.168.10.5 | |
| Domain (A1) | `Domain`, `PartOfDomain` | agace.local, True | |
| Windows version (A2) | `Caption` | Windows Server 2016 Standard | |
| PowerShell (A2) | `Major`/`Minor` | 5 / 1 | |
| Time zone (A8) | `tzutil /g` | Central Standard Time | |
| Shares users see today | `Name`, `Path` | Sistemas → W:\Sistemas | |
| Office public IP (`ONPREM_PUBLIC_IP`) | last line | 201.x.x.x | |

Two more questions for AGACE IT or the internet provider (ISP):

1. **What brand/model is the firewall?** On AGACE-FS01, open a browser at `https://<firewall/router IP>` (e.g. `https://192.168.10.1`). The login page usually shows the brand (FortiGate, SonicWall, MikroTik, Cisco/Meraki, pfSense…). Also find out **who has the admin password**: AGACE IT, an outside provider, or the ISP.
2. **Is the public IP fixed ("IP fija")?** It must be fixed for the VPN. It usually says so on the ISP bill, or call the ISP. If it is not fixed, ask the ISP for one; it is usually a small monthly fee.

---

## Part B: Google account, billing and project (🌐)

### B.1 Choose the Google account that will own this

Use an account **AGACE controls long-term**: for example a Google Workspace account on the AGACE domain if they have one, or a new Gmail created for this, such as `ti.agace.gcp@gmail.com`. Avoid a personal account. In B.5 you add yourself (and later AGACE IT) as Owners, so nobody is locked out if one person leaves.

### B.2 Sign in and create the billing account

1. Go to **https://console.cloud.google.com** and sign in with the account from B.1.
2. Accept the terms. Country: **Mexico**.
3. Left menu (☰) → **Billing** → **Create account** (or **Manage billing accounts → Create account**).
4. Enter the payer details (AGACE's RFC/business name if AGACE pays) and a card.
5. **Important:** if Google offers or starts a **Free Trial** ($300 credit), you must click **Activate full account** (or **Upgrade**). It is a banner at the top of the console, or under Billing → Overview.
   - Free Trial accounts **cannot create Windows Server VMs** and **cannot request quota increases**. Both are required here.
   - Upgrading keeps any unused credit.

✅ You should see: Billing → Overview shows the account with **no "Free trial" label**.

### B.3 Create the project

1. Top bar → click the project picker (next to "Google Cloud") → **New project**.
2. Project name: `AGACE Migracion`.
3. Under the name, click **Edit** next to the Project ID and type `agace-migracion-2026`. If Google says it is taken, add letters (e.g. `agace-migracion-2026-mx`).
4. **Write down the exact Project ID.** Every command uses it.
5. Billing account: the one from B.2. Location: **No organization** (or AGACE's organization if they have Workspace). → **Create**.

✅ You should see: the project name in the top bar.

### B.4 Budget alert (so costs never surprise anyone)

1. ☰ → **Billing** → **Budgets & alerts** → **Create budget**.
2. Name `AGACE monthly`. Projects: `AGACE Migracion`. Next.
3. Amount type **Specified amount**: `2000` (USD per month; adjust after Google Support's pricing).
4. Thresholds: 50%, 90%, 100% (actual). Tick **Email alerts to billing admins and users**. **Finish**.

> A budget **only sends emails**. It does not stop anything. To stop spending you stop or delete resources (Part M).

### B.5 Add a second Owner

☰ → **IAM & Admin** → **IAM** → **Grant access** → New principals: your work email (and later AGACE IT's) → Role: **Basic → Owner** → **Save**.

---

## Part C: Cloud Shell and your settings file (⌨️)

1. In the console top bar, click the **Activate Cloud Shell** icon ( **>_** ). A terminal opens at the bottom. Click **Authorize** if asked.
2. Paste this block **once**. It creates a small settings file that survives between sessions. **Change the line marked ⟵ to your Project ID from B.3.** Leave the three on-premises lines as they are for now; you will fix them in Part J.

```bash
cat > ~/agace-env.sh <<'EOF'
export PROJECT=agace-migracion-2026        # ⟵ your Project ID (B.3)
export REGION=northamerica-south1          # Queretaro, Mexico (A6)
export ZONE=northamerica-south1-a
export VM=agace-gcp-fs01
export VM_IP=10.50.0.10
export SA=sa-agace-fs@${PROJECT}.iam.gserviceaccount.com
export HOT_BUCKET=gs://${PROJECT}-operacion-activa
export COLD_BUCKET=gs://${PROJECT}-archivo-historico-2012-2020
# --- fill in from Part A before Part J ---
export SOURCE_IP=CHANGE-ME                 # AGACE-FS01 IP, e.g. 192.168.10.20
export ONPREM_LAN=CHANGE-ME                # office network, e.g. 192.168.10.0/24
export ONPREM_PUBLIC_IP=CHANGE-ME          # office fixed public IP
EOF
echo 'source ~/agace-env.sh' >> ~/.bashrc
source ~/agace-env.sh
gcloud config set project $PROJECT
echo "Project: $PROJECT | Hot bucket: $HOT_BUCKET | Cold bucket: $COLD_BUCKET"
```

If your Project ID is different, edit the file with `nano ~/agace-env.sh`: change the value, then press **Ctrl+O**, **Enter**, **Ctrl+X**. Then run `source ~/agace-env.sh`.

✅ You should see: `Updated property [core/project]` and the three names. **Every later block assumes these variables.** If Cloud Shell was closed, a new session loads them automatically, because the block above added the `source` line to `.bashrc`.

---

## Part D: Turn on services and check quotas (⌨️ + 🌐)

### D.1 Enable the APIs (takes about 1 minute)

```bash
gcloud services enable compute.googleapis.com storage.googleapis.com iap.googleapis.com
```

✅ `Operation ... finished successfully.`

### D.2 Check the quotas

New projects start with low limits on disk space. Check them:

```bash
gcloud compute regions describe $REGION --flatten=quotas \
  --format="table(quotas.metric,quotas.limit,quotas.usage)" | grep -E 'METRIC|^CPUS |SSD_TOTAL_GB|^DISKS_TOTAL_GB|STATIC_ADDRESSES|IN_USE_ADDRESSES'
```

| Metric | Needed for this project | Why |
|---|---|---|
| `CPUS` | ≥ 8 | the e2-standard-8 server |
| `SSD_TOTAL_GB` | ≥ 7,000 | boot disk + active-data disk (pd-balanced counts as "SSD") |
| `DISKS_TOTAL_GB` | ≥ 9,000 (≥ 13,000 for a full replica) | 2012–2020 staging / replica disk (pd-standard) |
| `STATIC_ADDRESSES`, `IN_USE_ADDRESSES` | ≥ 2 | VPN IP, Cloud NAT |

### D.3 Request increases now (approval can take up to 2 business days)

For each metric below the "needed" value:

1. 🌐 ☰ → **IAM & Admin** → **Quotas & system limits**.
2. In the filter type the name: *Persistent Disk SSD (GB)* (= SSD_TOTAL_GB), *Persistent Disk Standard (GB)* (= DISKS_TOTAL_GB) or *CPUs*. Then filter **region: northamerica-south1**.
3. Tick the row → **Edit quotas** → new value → justification:

   > Migration of a 12 TB Windows file server for a customs brokerage (legal 5-year retention). One Windows Server VM with a 6 TB pd-balanced data disk and an 8–12 TB pd-standard staging disk in northamerica-south1.

4. **Submit**. You get an email when it is approved.

You can continue with Parts E–I while you wait: the disks start small (H.1) and grow later.

---

## Part E: Private network (⌨️)

Paste the whole block. Each line prints `Created [...]`.

```bash
# Private network and subnet for AGACE in Queretaro. Google APIs are reachable without a public IP.
gcloud compute networks create agace-vpc --subnet-mode=custom
gcloud compute networks subnets create agace-subnet-mx --network=agace-vpc --region=$REGION \
  --range=10.50.0.0/24 --enable-private-ip-google-access

# Outbound internet for the server (Windows Update, PowerShell 7 download). It still has NO public IP.
gcloud compute routers create agace-router --network=agace-vpc --region=$REGION
gcloud compute routers nats create agace-nat --router=agace-router --region=$REGION \
  --nat-all-subnet-ip-ranges --auto-allocate-nat-external-ips

# Remote Desktop only through Google's secure tunnel (IAP). Nothing is open to the internet.
gcloud compute firewall-rules create agace-allow-iap-rdp --network=agace-vpc --direction=INGRESS \
  --action=ALLOW --rules=tcp:3389 --source-ranges=35.235.240.0/20 --target-tags=agace-fs
```

✅ Check:

```bash
gcloud compute networks subnets list --network=agace-vpc
gcloud compute routers nats list --router=agace-router --region=$REGION
```

Expected: one subnet `10.50.0.0/24` and one NAT `agace-nat`.

> The rule that lets AGACE-FS01 reach the server (SMB port 445) is created in Part J. It needs the server IP from Part A.

---

## Part F: Service account, buckets and lifecycle (⌨️ + 🌐)

### F.1 Identity for the server

```bash
gcloud iam service-accounts create sa-agace-fs --display-name="AGACE file server VM"
```

### F.2 The two buckets

```bash
# Active data: Standard class, versioning ON (keeps old versions of changed/deleted files)
gcloud storage buckets create $HOT_BUCKET --location=$REGION \
  --default-storage-class=STANDARD --uniform-bucket-level-access --public-access-prevention
gcloud storage buckets update $HOT_BUCKET --versioning

# 2012-2020 archive: Archive class from day 0
gcloud storage buckets create $COLD_BUCKET --location=$REGION \
  --default-storage-class=ARCHIVE --uniform-bucket-level-access --public-access-prevention
```

> ⚠️ **Do NOT add a retention policy or lock now.** Runbook 3.4 says to do that only after every 2012–2020 file is uploaded and verified (Gate A) **and** Legal approves (A7). Locking is permanent.

### F.3 Lifecycle rules on the active bucket (runbook 3.3)

```bash
cat > ~/lifecycle-operacion-activa.json <<'EOF'
{
  "lifecycle": {
    "rule": [
      { "action": { "type": "SetStorageClass", "storageClass": "COLDLINE" },
        "condition": { "daysSinceCustomTime": 1826, "matchesStorageClass": ["STANDARD"], "isLive": true } },
      { "action": { "type": "SetStorageClass", "storageClass": "COLDLINE" },
        "condition": { "age": 1826, "matchesStorageClass": ["STANDARD"], "isLive": true } },
      { "action": { "type": "SetStorageClass", "storageClass": "ARCHIVE" },
        "condition": { "daysSinceCustomTime": 2557, "matchesStorageClass": ["STANDARD", "COLDLINE"], "isLive": true } },
      { "action": { "type": "SetStorageClass", "storageClass": "ARCHIVE" },
        "condition": { "age": 2557, "matchesStorageClass": ["STANDARD", "COLDLINE"], "isLive": true } },
      { "action": { "type": "SetStorageClass", "storageClass": "COLDLINE" },
        "condition": { "daysSinceNoncurrentTime": 30, "matchesStorageClass": ["STANDARD"], "isLive": false } },
      { "action": { "type": "Delete" },
        "condition": { "daysSinceNoncurrentTime": 1826, "isLive": false } }
    ]
  }
}
EOF
gcloud storage buckets update $HOT_BUCKET --lifecycle-file=$HOME/lifecycle-operacion-activa.json
```

This is the same content as `gcp/lifecycle-operacion-activa.json` in the repository.

### F.4 Let the server use the buckets

```bash
gcloud storage buckets add-iam-policy-binding $HOT_BUCKET  --member=serviceAccount:$SA --role=roles/storage.objectAdmin
gcloud storage buckets add-iam-policy-binding $COLD_BUCKET --member=serviceAccount:$SA --role=roles/storage.objectAdmin
```

If you get `does not exist`, the account from F.1 is still being created. Wait 1 minute and paste again.

✅ Check (send me this output; it contains nothing secret):

```bash
gcloud storage buckets describe $HOT_BUCKET  --format="yaml(name,location,default_storage_class,versioning_enabled,public_access_prevention,lifecycle_config.rule.len())"
gcloud storage buckets describe $COLD_BUCKET --format="yaml(name,location,default_storage_class,public_access_prevention,retention_policy)"
```

Expected:
- active bucket: `STANDARD`, `versioning_enabled: true`, `public_access_prevention: enforced`, 6 lifecycle rules;
- archive bucket: `ARCHIVE`, `enforced`, **no** `retention_policy`.

### F.5 Audit log of who reads files (🌐, runbook 3.5)

☰ → **IAM & Admin** → **Audit Logs** → filter **Google Cloud Storage** → tick the row → on the right tick **Data Read** and **Data Write** → **Save**.

Every download (e.g. during a SAT/ANAM audit) is then recorded. During the initial upload this creates many log lines. The first 50 GiB/month of logs are free; we'll watch it on the bill.

---

## Part G: Daily snapshot schedule (⌨️)

```bash
gcloud compute resource-policies create snapshot-schedule agace-daily-0600 --region=$REGION \
  --max-retention-days=14 --on-source-disk-delete=keep-auto-snapshots --daily-schedule --start-time=12:00
```

12:00 UTC = 6:00 AM in Matamoros. This is the daily backup's restore points: 14 days, one per day. It is attached to the disk in H.2.

---

## Part H: The Windows server (⌨️)

### H.1 Create the server

The runbook's `n2-standard-8` is **not offered in Querétaro**. The region offers E2, N4, C3D, C4, C4A and Z3. This guide uses **e2-standard-8** (8 vCPU, 32 GB), which supports the disk types the design needs.

The two data disks start at **1,000 GB** so you don't pay for empty space before the inventory gives real sizes. They grow online in H.4.

```bash
gcloud compute instances create $VM --zone=$ZONE --machine-type=e2-standard-8 \
  --image-family=windows-2022 --image-project=windows-cloud \
  --boot-disk-size=200GB --boot-disk-type=pd-balanced \
  --network-interface=subnet=agace-subnet-mx,private-network-ip=$VM_IP,no-address \
  --tags=agace-fs --service-account=$SA --scopes=cloud-platform \
  --create-disk=name=agace-hot,device-name=agace-hot,size=1000GB,type=pd-balanced,auto-delete=no \
  --create-disk=name=agace-cold-staging,device-name=agace-cold-staging,size=1000GB,type=pd-standard,auto-delete=no \
  --deletion-protection
```

| If you see | Meaning / fix |
|---|---|
| `Quota 'SSD_TOTAL_GB' exceeded` | Wait for D.3 approval, or change `size=1000GB` on agace-hot to `500GB` |
| `ZONE_RESOURCE_POOL_EXHAUSTED` | Change `ZONE` to `northamerica-south1-b` in `~/agace-env.sh`, `source` it, and retry |
| `free trial` / `billing` | Go back to B.2 step 5 |

### H.2 Attach the daily snapshot to the active-data disk

```bash
gcloud compute disks add-resource-policies agace-hot --resource-policies=agace-daily-0600 --zone=$ZONE
```

### H.3 Wait for Windows' first boot (5–10 minutes), then create the admin password

```bash
until gcloud compute instances get-serial-port-output $VM --zone=$ZONE 2>/dev/null | grep -q "Instance setup finished"; do echo "Windows still setting up..."; sleep 30; done; echo READY
gcloud compute reset-windows-password $VM --zone=$ZONE --user=agace-admin --quiet
```

✅ The output shows `ip_address`, `password` and `username`. **Copy the password into a password manager now.** Do not email it or put it in the repository. If you lose it, run the second line again for a new one.

### H.4 Later, after tonight's inventory: grow the disks

`summary_folders.csv` gives the Hot and Cold totals (runbook 1.5). Sizes:

| Disk | Runbook design | Full replica (everything on the server) |
|---|---|---|
| `agace-hot` (pd-balanced) | Hot TB × 1.3 | same |
| `agace-cold-staging` (pd-standard) | Cold TB × 1.1, **deleted after Gate A** | Cold TB × 1.3, **kept** and attached to the snapshot schedule |

Disks can grow but **never shrink**. Example with 4.6 TB Hot and 6.6 TB Cold:

```bash
gcloud compute disks resize agace-hot          --size=6000GB --zone=$ZONE --quiet
gcloud compute disks resize agace-cold-staging --size=7300GB --zone=$ZONE --quiet
```

Then 🖥️ in PowerShell (Administrator) on the server:

```powershell
Update-HostStorageCache
Resize-Partition -DriveLetter E -Size (Get-PartitionSupportedSize -DriveLetter E).SizeMax
Resize-Partition -DriveLetter S -Size (Get-PartitionSupportedSize -DriveLetter S).SizeMax
Get-Volume E, S | Format-Table DriveLetter, FileSystemLabel, @{n='SizeGB';e={[int]($_.Size/1GB)}}
```

---

## Part I: Connect to the server and prepare Windows (💻 + 🖥️)

### I.1 One-time setup on your Mac (💻)

You need two free programs:

1. **Windows App**, Microsoft's Remote Desktop app: Mac App Store → search "Windows App" → Get.
2. **Google Cloud CLI**: open **Terminal** and paste `brew install --cask gcloud-cli`. *If you prefer, ask me to install it for you; it's this Mac.*

Then, in Terminal:

```bash
gcloud auth login                       # a browser opens: sign in with the B.1 account, click Allow
gcloud config set project agace-migracion-2026      # ⟵ your Project ID
```

### I.2 Open the secure tunnel (💻, every time you want to connect)

```bash
gcloud compute start-iap-tunnel agace-gcp-fs01 3389 --local-host-port=localhost:13389 --zone=northamerica-south1-a
```

✅ `Listening on port [13389].` **Leave this Terminal window open** while you use Remote Desktop. Ctrl+C closes the tunnel.

### I.3 Remote Desktop (💻)

Windows App → **+** → **Add PC** → PC name `localhost:13389` → Credentials: **Add credentials** → user `agace-admin`, the password from H.3 → **Add** → double-click the PC → **Continue** on the certificate warning (normal the first time).

### I.4 Prepare Windows (🖥️)

On the server: Start → type **PowerShell** → right-click **Windows PowerShell** → **Run as administrator**. Paste one block at a time.

**Block 1: time zone, long paths, file server role**

Use the exact value from `tzutil /g` on AGACE-FS01 (Part A). If you don't have it yet, Matamoros normally uses `Central Standard Time`.

```powershell
tzutil /s "Central Standard Time"
tzutil /g
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -Value 1
Install-WindowsFeature FS-FileServer
```

✅ `tzutil /g` prints the zone; Install-WindowsFeature shows `Success True`.

**Block 2: find the two data disks (look before formatting)**

```powershell
Get-Disk | Format-Table Number, SerialNumber, PartitionStyle, @{n='GB';e={[int]($_.Size/1GB)}}
$hot  = (Get-Disk | Where-Object SerialNumber -like '*agace-hot*').Number
$cold = (Get-Disk | Where-Object SerialNumber -like '*agace-cold-staging*').Number
"Hot disk = $hot   Cold disk = $cold"
```

✅ Expected: three disks. Disk 0 ≈ 200 GB is Windows, and two others ≈ 1000 GB with `PartitionStyle RAW`. The last line shows two **different numbers, neither 0**. **If either is blank or 0, STOP and send me the table.**

**Block 3: format them** (only after Block 2 looks right; this erases those two disks, which are new and empty)

```powershell
if ($hot -and $cold -and $hot -ne 0 -and $cold -ne 0) {
  Initialize-Disk -Number $hot -PartitionStyle GPT
  New-Partition -DiskNumber $hot -UseMaximumSize -DriveLetter E | Format-Volume -FileSystem NTFS -AllocationUnitSize 8192 -NewFileSystemLabel AGACE-HOT -Confirm:$false
  Initialize-Disk -Number $cold -PartitionStyle GPT
  New-Partition -DiskNumber $cold -UseMaximumSize -DriveLetter S | Format-Volume -FileSystem NTFS -AllocationUnitSize 8192 -NewFileSystemLabel AGACE-COLD-STAGING -Confirm:$false
} else { 'STOP: disk numbers not found' }
Get-Volume | Where-Object DriveLetter | Format-Table DriveLetter, FileSystemLabel, @{n='SizeGB';e={[int]($_.Size/1GB)}}
```

✅ Drives `C`, `E AGACE-HOT` and `S AGACE-COLD-STAGING`. The 8 KB cluster size lets the volumes grow past 16 TB later.

**Block 4: folders, migration account, shares**

The server isn't in AGACE's domain yet (Part K), so robocopy uses a **local** account `svc-migration` for now. Choose a strong password (20+ characters) and save it in the password manager. AGACE-FS01 needs it in Part J.

```powershell
New-Item -ItemType Directory -Force E:\AGACE\Hot, E:\AGACE\scripts, E:\AGACE\gcs-logs, S:\AGACE\Cold\_control | Out-Null
$pw = Read-Host -AsSecureString 'New password for local svc-migration'
New-LocalUser -Name svc-migration -Password $pw -PasswordNeverExpires -AccountNeverExpires -Description 'AGACE migration robocopy - remove after project'
Add-LocalGroupMember -Group 'Backup Operators' -Member svc-migration
icacls E:\AGACE /grant "svc-migration:(OI)(CI)F" | Out-Null
icacls S:\AGACE /grant "svc-migration:(OI)(CI)F" | Out-Null
New-SmbShare -Name 'Hot$'       -Path 'E:\AGACE\Hot'  -FullAccess "$env:COMPUTERNAME\svc-migration", 'BUILTIN\Administrators' -CachingMode None
New-SmbShare -Name 'ColdStage$' -Path 'S:\AGACE\Cold' -FullAccess "$env:COMPUTERNAME\svc-migration", 'BUILTIN\Administrators' -CachingMode None
Enable-NetFirewallRule -DisplayGroup 'File and Printer Sharing'
Get-SmbShare | Format-Table Name, Path
```

✅ `Hot$ → E:\AGACE\Hot` and `ColdStage$ → S:\AGACE\Cold` are listed.

**Block 5: PowerShell 7 (needed by scripts 07 and 08)**

```powershell
$msi = "$env:TEMP\PowerShell-7.4.22-win-x64.msi"
Invoke-WebRequest 'https://github.com/PowerShell/PowerShell/releases/download/v7.4.22/PowerShell-7.4.22-win-x64.msi' -OutFile $msi -UseBasicParsing
Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn ADD_PATH=1" -Wait
& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
```

✅ `7.4.22`. If the download fails, the NAT from Part E is missing.

**Block 6: check the server can reach the buckets**

The gcloud tool is preinstalled on Google's Windows images. This reads the project ID from the server itself, so there is nothing to type.

```powershell
$p = Invoke-RestMethod -Headers @{ 'Metadata-Flavor' = 'Google' } 'http://metadata.google.internal/computeMetadata/v1/project/project-id'
"test $(Get-Date -Format s)" | Out-File "$env:TEMP\agace-test.txt" -Encoding ascii
gcloud storage cp "$env:TEMP\agace-test.txt" "gs://$p-operacion-activa/_setup-test/agace-test.txt"
gcloud storage ls "gs://$p-operacion-activa/_setup-test/"
gcloud storage rm "gs://$p-operacion-activa/_setup-test/agace-test.txt"
gcloud storage ls "gs://$p-archivo-historico-2012-2020"
```

✅ The test file is listed, then removed, and the last line prints nothing (the bucket is empty) with **no** `AccessDenied` / `403`.

**Block 7: Windows Update** (once now, then monthly; never during a copy night)

Start → **Settings** → **Windows Update** → **Check for updates** → install → restart if asked. After a restart, reconnect with I.2 + I.3.

### I.5 What the scripts need to know about the bucket names

Your buckets have the project ID in front: `gs://<project>-operacion-activa`. Scripts 07 and 08 default to `gs://agace-operacion-activa`, so the scheduled tasks on the server (runbook 4.5) must pass the real names, for example:

`-HotBucket gs://agace-migracion-2026-operacion-activa -ColdBucket gs://agace-migracion-2026-archivo-historico-2012-2020`

I'll set this when we register the tasks.

---

## Part J: VPN between the AGACE office and Google Cloud (⌨️ + 🏢 firewall admin)

This is the private link that robocopy uses. It needs the firewall admin from Part A, because they configure the AGACE side.

This guide uses **Classic VPN with static routes**. It works with almost every firewall and its 99.9% SLA is enough for a nightly copy. If the firewall admin says the firewall supports **BGP** (most FortiGate, SonicWall, MikroTik and Cisco do), tell me and I'll give you the HA VPN version (99.99%, two tunnels) instead.

### J.1 Fill in the on-prem values

```bash
nano ~/agace-env.sh       # replace the three CHANGE-ME values with the Part A answers; Ctrl+O, Enter, Ctrl+X
source ~/agace-env.sh
echo "SOURCE_IP=$SOURCE_IP  ONPREM_LAN=$ONPREM_LAN  ONPREM_PUBLIC_IP=$ONPREM_PUBLIC_IP"
```

✅ Three real values, no `CHANGE-ME`.

### J.2 Allow AGACE-FS01 to reach the server

```bash
gcloud compute firewall-rules create agace-allow-smb-onprem --network=agace-vpc --direction=INGRESS \
  --action=ALLOW --rules=tcp:445 --source-ranges=$SOURCE_IP/32 --target-tags=agace-fs
gcloud compute firewall-rules create agace-allow-mgmt-onprem --network=agace-vpc --direction=INGRESS \
  --action=ALLOW --rules=icmp,tcp:3389 --source-ranges=$ONPREM_LAN --target-tags=agace-fs
```

The second rule lets AGACE IT ping the server and use Remote Desktop from the office once the VPN is up.

### J.3 Google side of the VPN

```bash
gcloud compute addresses create agace-vpn-ip --region=$REGION
export VPN_IP=$(gcloud compute addresses describe agace-vpn-ip --region=$REGION --format='value(address)')
echo "export VPN_IP=$VPN_IP" >> ~/agace-env.sh
gcloud compute target-vpn-gateways create agace-vpn-gw --network=agace-vpc --region=$REGION
gcloud compute forwarding-rules create agace-vpn-esp     --region=$REGION --ip-protocol=ESP --address=$VPN_IP --target-vpn-gateway=agace-vpn-gw
gcloud compute forwarding-rules create agace-vpn-udp500  --region=$REGION --ip-protocol=UDP --ports=500  --address=$VPN_IP --target-vpn-gateway=agace-vpn-gw
gcloud compute forwarding-rules create agace-vpn-udp4500 --region=$REGION --ip-protocol=UDP --ports=4500 --address=$VPN_IP --target-vpn-gateway=agace-vpn-gw

# Shared secret: generated here, stored only in your Cloud Shell home (readable by you only)
openssl rand -hex 24 > ~/agace-vpn-secret.txt && chmod 600 ~/agace-vpn-secret.txt

gcloud compute vpn-tunnels create agace-tunnel-1 --region=$REGION --target-vpn-gateway=agace-vpn-gw \
  --peer-address=$ONPREM_PUBLIC_IP --shared-secret="$(cat ~/agace-vpn-secret.txt)" --ike-version=2 \
  --local-traffic-selector=0.0.0.0/0 --remote-traffic-selector=0.0.0.0/0
gcloud compute routes create agace-route-onprem --network=agace-vpc --destination-range=$ONPREM_LAN \
  --next-hop-vpn-tunnel=agace-tunnel-1 --next-hop-vpn-tunnel-region=$REGION
echo "Google VPN IP: $VPN_IP"
```

> If the firewall admin says the firewall only does **policy-based** VPN (some SonicWall/Cisco setups), delete and recreate the tunnel with `--local-traffic-selector=10.50.0.0/24 --remote-traffic-selector=$ONPREM_LAN`, keeping everything else the same.

### J.4 Send the firewall admin these settings

Send this table **by email or chat**. Send the **shared secret separately** by phone, WhatsApp call or a password-manager share, never in the same email. To see the secret: `cat ~/agace-vpn-secret.txt`.

| Setting | Value |
|---|---|
| Remote (Google) gateway IP | value of `$VPN_IP` (printed above) |
| Local (AGACE) public IP | `$ONPREM_PUBLIC_IP` |
| IKE version | IKEv2 |
| Authentication | Pre-shared key (sent separately) |
| Phase 1 (IKE) | AES-256-CBC, SHA-256 (integrity and PRF), DH group 14, lifetime 36000 s |
| Phase 2 (IPsec/ESP) | AES-256-CBC, SHA-256, PFS DH group 14, lifetime 10800 s |
| Tunnel type | Route-based (VTI), traffic selectors 0.0.0.0/0 ↔ 0.0.0.0/0. Policy-based: local `$ONPREM_LAN`, remote `10.50.0.0/24` |
| Route on the firewall | `10.50.0.0/24` → the tunnel |
| Firewall policy | Allow AGACE LAN → `10.50.0.0/24` (TCP 445, TCP 3389, ICMP). If the server will join the domain: allow `10.50.0.0/24` → domain controller (TCP/UDP 53, 88, 389, 445, 464, TCP 135, 636, 3268, 49152–65535, UDP 123) |
| NAT | **No NAT** for traffic between the AGACE LAN and 10.50.0.0/24 |
| MTU / MSS | TCP MSS clamp **1360** on the tunnel (important for copy speed) |
| Dead peer detection | On |

### J.5 Check the tunnel (⌨️)

```bash
gcloud compute vpn-tunnels describe agace-tunnel-1 --region=$REGION --format='value(status,detailedStatus)'
```

| Output | Meaning |
|---|---|
| `ESTABLISHED  Tunnel is up and running.` | ✅ Done |
| `WAITING_FOR_FULL_CONFIG`, `NO_INCOMING_PACKETS`, `FIRST_HANDSHAKE` | The AGACE side is not configured yet, or a setting doesn't match |
| `AUTHORIZATION_ERROR` | The shared secret doesn't match |
| `NEGOTIATION_FAILURE` | Phase 1/2 settings don't match the table |

### J.6 Test from AGACE-FS01 (🏢, PowerShell as administrator)

```powershell
Test-NetConnection 10.50.0.10 -Port 445
```

✅ `TcpTestSucceeded : True`. Then let AGACE-FS01 use the name the scripts expect, and test writing with the local `svc-migration` account (it asks for the password from I.4 Block 4):

```powershell
Add-Content -Path "$env:SystemRoot\System32\drivers\etc\hosts" -Value "`r`n10.50.0.10`tagace-gcp-fs01.agace.local`tagace-gcp-fs01"
net use \\agace-gcp-fs01.agace.local\Hot$ /user:agace-gcp-fs01\svc-migration *
Set-Content \\agace-gcp-fs01.agace.local\Hot$\_vpn-test.txt 'ok'
Get-Item \\agace-gcp-fs01.agace.local\Hot$\_vpn-test.txt
Remove-Item \\agace-gcp-fs01.agace.local\Hot$\_vpn-test.txt
```

✅ The file is listed and removed. **This is Gate G0's "shares reachable from FS01"**, and the runbook's speed test (pilot, Gate P) can start.

> The hosts-file line is temporary. Remove it after Part K, when the domain DNS knows the server.

---

## Part K: Join AGACE's domain (only if A1 = yes; needs the VPN and the firewall policy for the domain controller)

This lets robocopy copy folder permissions (`/COPY:DATSO`) so that the replica has the same security as the original. Until then, copies use `/COPY:DAT` (data, attributes and timestamps, no permissions).

🖥️ PowerShell as administrator. Replace the DC IP and the domain with the Part A values:

```powershell
$dc = '192.168.10.5'           # ⟵ DNS server from Part A
Test-NetConnection $dc -Port 389
Set-DnsClientServerAddress -InterfaceIndex (Get-NetAdapter | Where-Object Status -eq 'Up').ifIndex -ServerAddresses $dc, '169.254.169.254'
Resolve-DnsName agace.local     # ⟵ domain from Part A
Add-Computer -DomainName agace.local -Credential (Get-Credential -Message 'AGACE domain admin') -Restart
```

After the restart, reconnect (I.2/I.3) and log in as the domain admin. Then give the domain migration account the same rights as the local one:

```powershell
Add-LocalGroupMember -Group 'Backup Operators' -Member 'AGACE\svc-migration'
icacls E:\AGACE /grant "AGACE\svc-migration:(OI)(CI)F" | Out-Null
icacls S:\AGACE /grant "AGACE\svc-migration:(OI)(CI)F" | Out-Null
Grant-SmbShareAccess -Name 'Hot$'       -AccountName 'AGACE\svc-migration' -AccessRight Full -Force
Grant-SmbShareAccess -Name 'ColdStage$' -AccountName 'AGACE\svc-migration' -AccessRight Full -Force
```

---

## Part L: The same look for users (later, not before the baseline copy)

During the 6–18 months, users keep working on AGACE-FS01. The replica's user shares should be **read-only** so nobody edits the copy by mistake: the nightly copy would overwrite their change. After the baseline, we create shares on agace-gcp-fs01 with the **same names** that `Get-SmbShare` showed in Part A, for example `Sistemas` → `E:\AGACE\Hot\W_Sistemas`, with read-only access. If AGACE ever has to switch, users map the same drive letters to the new server. I'll write this step once we have the share list.

---

## Part M: Costs and how to pause

### M.1 Monthly estimate (list prices, northamerica-south1; Google Support may lower them)

| Item | Example size | ≈ US$/month |
|---|---|---|
| Server e2-standard-8, on 24/7 | 8 vCPU / 32 GB | 213 |
| Windows Server license (charged per vCPU-hour) | 8 vCPU | 269 |
| Boot disk pd-balanced | 200 GB | 22 |
| `agace-hot` pd-balanced | 6,000 GB | 654 |
| `agace-cold-staging` pd-standard (until Gate A; permanent for a full replica) | 7,300 GB | 318 |
| Daily snapshots of `agace-hot`, 14 days (estimate; depends on daily change) | ≈ 4.6 TB used | 230–300 |
| Bucket operacion-activa, Standard | 4,000 GB | 80–92 |
| Bucket archivo-historico, Archive | 7,000 GB | 8–10 |
| Classic VPN tunnel + IP | 1 tunnel | ≈ 40 |
| Cloud NAT | – | < 5 |
| **Total during migration** | | **≈ 1,840–1,920** |
| **After Gate A (staging disk deleted, runbook design)** | | **≈ 1,520–1,600** |

> Runbook 3.8 lists only disks and buckets. It leaves out the server, the Windows license, snapshots and VPN (≈ US$800/month).

Ways to lower the cost for the 6–18-month replica period, to raise with Google Support:
- **Run the server only for the copy window**, e.g. 10 PM–8 AM, with a Compute Engine instance schedule. Compute and license costs are charged only while it runs.
- **Downsize to e2-standard-4 after the baseline.** Nightly deltas are small.
- **Keep snapshots 7 days instead of 14.** The versioned bucket already keeps 5 years of changed and deleted file versions.

### M.2 Pause or stop spending

- **Stop the server** (stops compute and Windows license charges; disks and buckets are still billed): `gcloud compute instances stop $VM --zone=$ZONE`. Start it with `... start ...`.
- **Never delete** `agace-hot`, `agace-cold-staging`, the buckets or the project without written approval. That is AGACE's data.

---

## Checkpoints: what to send me

| After | Send |
|---|---|
| D.2 | the quota table |
| F.4 | the two `describe` outputs |
| H.1 / H.3 | any error text. **Never** the password |
| I.4 | screenshots of Blocks 2, 3, 5, 6 |
| J.5 / J.6 | tunnel status and `TcpTestSucceeded` |

## Gate G0 checklist (runbook Section 7, items 4–8)

| ☐ | Item | Part |
|---|---|---|
| ☐ | Billing is a paid account (not Free Trial); budget alert set; 2 Owners | B |
| ☐ | APIs on; quota increases approved | D |
| ☐ | VPC, subnet 10.50.0.0/24, Cloud NAT, IAP RDP rule | E |
| ☐ | Buckets: activa (Standard, versioning, 6 lifecycle rules), histórico (Archive, **no** retention yet), public access prevented | F |
| ☐ | Data Access audit logs on for Cloud Storage | F.5 |
| ☐ | Server created; snapshot schedule on agace-hot; password in password manager | G, H |
| ☐ | Time zone = source; long paths; E: and S: formatted; shares Hot$ / ColdStage$; PowerShell 7; bucket test OK | I |
| ☐ | VPN ESTABLISHED; FS01 → 10.50.0.10:445 True; test file written from FS01 | J |
| ☐ | Domain joined (if A1 = yes) | K |
