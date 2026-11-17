# AGACE Asesoría Y Gestoría Al Comercio Exterior S.C.
# Runbook: Migración de servidor de archivos Windows (varias unidades) → Google Cloud (Caliente/Frío)

| Concepto | Valor |
|---|---|
| Documento | AGACE-MIG-GCP-001, v1.0 (borrador para revisión y aprobación de AGACE) |
| Fecha | 16-nov-2026 |
| Alcance | Unidades origen C: (solo datos de negocio), D:\Informacion, F:\Lacie, G:\Seagate, W:\Sistemas (≈ 11.2 TB según Windows) |
| Destino | VM Windows Server en GCP (datos Calientes / FM2) + Cloud Storage (copia versionada de lo Caliente + clase Archive para 2012–2020) |
| Herramientas | Robocopy (nativo de Windows), PowerShell 5.1 en el origen, PowerShell 7 + gcloud CLI en la VM |
| Versión en inglés | `AGACE_GCP_Migration_Runbook_EN.md` (mismos comandos) |

Todos los scripts de este runbook se entregan también como archivos en `scripts/` y `gcp/`. Copie `scripts\*.ps1` a `C:\AGACE-Migration\scripts` en el servidor origen, y `07-*.ps1`, `08-*.ps1` y `09-*.ps1` a `E:\AGACE\scripts` en la VM. El código es idéntico en ambas versiones del documento. Los mensajes que imprimen los scripts están en inglés.

**Glosario:** *Caliente (Hot)* = datos activos para la operación diaria (FM2). *Frío (Cold)* = archivo histórico 2012–2020. *Unidad de migración* = carpeta que se clasifica, copia, verifica y reintenta como un todo. *Baseline* = copia inicial completa. *Sincronización diaria (Delta)* = copia de los cambios del día. *Corte (cutover)* = momento en que los usuarios pasan a trabajar en GCP.

---

## 0. Arquitectura, valores a reemplazar y supuestos

### 0.1 Arquitectura destino

```
 AGACE Matamoros (local)                       Google Cloud - northamerica-south1 (Queretaro)
 +-----------------------------+   HA VPN      +------------------------------------------------+
 | AGACE-FS01 (origen)         |  (IPsec)      | VM agace-gcp-fs01 (Windows Server 2022)        |
 |  C:  solo carpetas aprobadas| ------------> |  E: agace-hot (pd-balanced)   recurso Hot$     |--+--> gs://agace-operacion-activa
 |  D:\Informacion             |  SMB 3 / 445  |  S: agace-cold-staging (pd-std) recurso ColdStage$| |    STANDARD, versionado, ciclo de vida:
 |  F:\Lacie    (USB)          |  robocopy     |     (temporal, se elimina tras la Compuerta A) |  |    COLDLINE a 5 años, ARCHIVE a 7 años
 |  G:\Seagate  (USB)          |               +------------------------------------------------+  |
 |  W:\Sistemas                |                                                                   +--> gs://agace-archivo-historico-2012-2020
 +-----------------------------+                                                                        ARCHIVE desde el día 0, política de
                                                                                                         retención (bloqueada tras aprobación)
```

Flujo de datos:

1. Las unidades **Calientes** (el archivo más reciente es del 2021-01-01 o posterior) van por robocopy a `E:\AGACE\Hot` en la VM. Ahí trabajarán los usuarios de FM2 después del corte. Cada noche la VM copia E: al bucket Standard versionado. Esa copia ocurre dentro de GCP y no consume el enlace de internet.
2. Las unidades **Frías** (sin modificaciones desde 2020) van por robocopy al disco temporal `S:\AGACE\Cold`, se verifican y se suben al bucket Archive. Después se elimina el disco temporal, así que los datos fríos no se pagan a largo plazo como disco de VM.

### 0.2 Valores a reemplazar antes de ejecutar

| Valor usado en este runbook | Significado |
|---|---|
| `AGACE-FS01`, `192.168.10.20` | Servidor Windows origen y su IP |
| `agace.local` / `AGACE\` | Dominio de Active Directory (DNS / NetBIOS) |
| `AGACE\svc-migration` | Cuenta de servicio de la migración (robocopy, tareas programadas) |
| `agace-migracion` | ID del proyecto de GCP |
| `northamerica-south1`, `northamerica-south1-a` | Región / zona de GCP (Querétaro, México) |
| `agace-vpc`, `agace-subnet-mx`, `10.50.0.0/24` | VPC, subred y rango |
| `agace-gcp-fs01.agace.local`, `10.50.0.10` | VM destino |
| `sa-agace-fs@agace-migracion.iam.gserviceaccount.com` | Cuenta de servicio de la VM |
| `gs://agace-operacion-activa` | Bucket Caliente (los nombres de bucket son globales: agregue un sufijo único) |
| `gs://agace-archivo-historico-2012-2020` | Bucket de archivo histórico (Frío) |
| `2021-01-01` / `20210101` | Fecha de corte Caliente/Frío (LastWriteTime del archivo) |
| N1 = lun 23-nov-2026 … N10 = mié 02-dic-2026; noches de reserva 3 y 4 de dic; corte sáb 05-dic-2026 | Calendario de ejemplo |
| `C:\AGACE-Migration\{scripts,inventory,jobs,logs,monitor}` | Carpetas de trabajo en el origen |

### 0.3 Supuestos que deben confirmarse antes de la Compuerta 1

| # | Supuesto | Si no se cumple |
|---|---|---|
| A1 | Origen y VM están en el mismo dominio de AD, de modo que robocopy puede copiar los permisos NTFS de lo Caliente (`/COPY:DATSO`). | Si es grupo de trabajo: ejecutar `04-Run-Robocopy.ps1 -HotCopy /COPY:DAT` y volver a aplicar permisos de recurso compartido y NTFS en la VM. |
| A2 | El sistema operativo origen es Windows Server 2012 R2 o posterior (SMB 3.x, PowerShell 5.1). | Con 2008 R2: instalar WMF 5.1 y esperar menor rendimiento (SMB 2.1). |
| A3 | F: (LaCie) y G: (Seagate) son discos externos USB. | Se tratan como las unidades con mayor riesgo de falla (ver 1.1 y 6.3). |
| A4 | Los datos de FM2 son archivos. | Las bases de datos en uso (SQL Server `.mdf/.ldf/.ndf`, por ejemplo el back-end de FM2 o CONTPAQi), los `.pst/.ost` abiertos y similares deben moverse con el respaldo/restauración nativo de cada aplicación. Robocopy no debe copiarlos (ver 1.2). |
| A5 | El enlace de internet y la VPN sostienen ≥ 450–550 Mbps de noche. | Los 11.2 TB completos no caben en 10 noches. Se migra primero lo Caliente y lo Frío continúa después del corte (Sección 5). |
| A6 | Los datos deben residir en México, por eso la región es `northamerica-south1`. | Si no hay requisito de residencia, `us-south1` (Dallas) suele tener menor latencia desde Matamoros. Confirme que la serie de máquina y los tipos de disco necesarios existen en la región elegida. |
| A7 | El plazo legal de conservación (Ley Aduanera, CFF y reforma 2026) según lo interpreten los asesores de cumplimiento de AGACE. | Este runbook usa el **LastWriteTime** del archivo como aproximación de la fecha del documento. Los asesores deben confirmar la fecha de corte, cómo se cuentan los 5 años (normalmente desde la fecha de la operación/pedimento) y el periodo de bloqueo antes del paso 3.4. |
| A8 | Matamoros aplica horario de verano al estilo de EE. UU. La VM debe usar la misma zona horaria de Windows que el origen (`tzutil /g`). | De lo contrario, las ventanas `/RH` y las tareas programadas se desfasan una hora. |

### 0.4 Decisiones de diseño

* **Solo copiar, nunca mover.** No se usa `/MOV`, y no se usa `/MIR` ni `/PURGE` hasta el corte. Un disco USB que se vuelva a montar vacío haría que `/MIR` borrara el destino. El origen sigue siendo la fuente oficial hasta la aprobación final.
* **Unidad de migración = carpeta.** Cada carpeta de primer (o segundo) nivel se clasifica, copia, registra, verifica y reintenta como un todo. Un log por unidad deja una pista de auditoría por cliente. Un pedimento nunca queda separado del resto de su expediente.
* **El corte solo depende de lo Caliente.** FM2 necesita únicamente los datos Calientes. Lo Frío es un archivo estático y puede seguir cargándose después del corte sin afectar la operación. Esta es la principal palanca si el ancho de banda no alcanza.
* **Clasificar al cargar en vez de depender de la "edad" del ciclo de vida.** GCS cuenta la edad desde la subida, no desde la fecha del archivo (3.1). Lo Frío se escribe directo en Archive. Lo Caliente recibe una marca Custom-Time.

---

## 1. Inventario previo a la migración

### 1.1 Revisión previa en AGACE-FS01 (T-7 días)

```powershell
# Salud de discos/volúmenes - cualquier 'Warning', 'Unhealthy' o ReadErrorsUncorrected > 0 en F:/G: => Sección 6.3 ANTES de copiar
Get-PhysicalDisk | Sort-Object DeviceId | Format-Table DeviceId, FriendlyName, BusType, MediaType, HealthStatus, OperationalStatus, @{n='SizeTB';e={[math]::Round($_.Size/1TB,2)}}
Get-PhysicalDisk | Get-StorageReliabilityCounter | Format-Table DeviceId, Temperature, ReadErrorsUncorrected, ReadErrorsTotal, PowerOnHours
Get-Volume | Where-Object DriveLetter | Format-Table DriveLetter, FileSystemLabel, FileSystem, HealthStatus, @{n='UsedTB';e={[math]::Round(($_.Size-$_.SizeRemaining)/1TB,2)}}

# Mantener despiertos los discos USB durante toda la migración (suspensión selectiva USB / apagado de disco = desconexiones nocturnas típicas)
powercfg /change disk-timeout-ac 0
powercfg /change standby-timeout-ac 0
powercfg /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0
powercfg /setactive SCHEME_CURRENT

# Versiones y zona horaria (anotar el resultado en la lista de verificación)
$PSVersionTable.PSVersion; (Get-CimInstance Win32_OperatingSystem).Caption; tzutil /g
```

Además: en el Administrador de dispositivos, desmarque "Permitir que el equipo apague este dispositivo" en los concentradores raíz USB. Deje Windows Update en solo descarga (sin reinicio automático) en el origen y en la VM hasta el corte, y cree las carpetas `C:\AGACE-Migration\{scripts,inventory,jobs,logs,monitor}`.

Muchos gabinetes USB ocultan los datos SMART. Si F: o G: no muestran contadores de confiabilidad, ejecute la herramienta del fabricante (SeaTools / LaCie Toolkit) antes de N1.

### 1.2 Unidad C:: solo datos de negocio

C: contiene el sistema operativo y las aplicaciones (~650 GB). Nunca use `C:\` como origen de robocopy. El script siguiente lista las carpetas candidatas con datos de negocio y excluye Windows, Program Files, ProgramData, Recovery, `$Recycle.Bin`, System Volume Information, AppData de los perfiles y similares.

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

Abra `C_candidates.csv`, marque `Include = Y` en las carpetas que AGACE apruebe y agregue cada ruta aprobada como raíz adicional:

* en `01-Inventory.ps1 -Roots` / `-UnitDepth`, por ejemplo `'C:\Contabilidad'`
* en `03-Build-Jobs.ps1 -RootMap`, por ejemplo `'C:\Contabilidad' = 'C_Datos\Contabilidad'` o `'C:\Users\jperez\Documents' = 'C_Datos\Users\jperez\Documents'`

Localice en todas las unidades los archivos de bases de datos y buzones de correo en uso. Esos van por respaldo nativo, no por robocopy. Con `/L`, robocopy los lista rápidamente sin copiar nada:

```powershell
foreach ($r in 'C:\', 'D:\Informacion', 'F:\Lacie', 'G:\Seagate', 'W:\Sistemas') {
  robocopy $r NULL *.mdf *.ldf *.ndf *.pst *.ost *.accdb *.mdb /S /L /XJ /R:0 /W:0 /NJH /NDL /FP /BYTES /NC `
    /XD Windows "Program Files" "Program Files (x86)" '$RECYCLE.BIN' "System Volume Information" `
    /UNILOG+:C:\AGACE-Migration\inventory\db_and_mail_files.log
}
```

### 1.3 Inventario y clasificación Caliente/Frío

El script de inventario solo lee metadatos y no escribe nada en las unidades origen. Recorre cada raíz con .NET (soporta rutas largas, omite junctions, `$RECYCLE.BIN` y `System Volume Information`) y genera una fila por **unidad de migración**:

* **Unidad recursiva (`Recurse=True`):** la carpeta ubicada `UnitDepth` niveles debajo de la raíz, por ejemplo `W:\Sistemas\Clientes\ACME` con profundidad 2.
* **Unidad de archivos sueltos (`Recurse=False`):** archivos que están directamente en una carpeta menos profunda, por ejemplo los archivos sueltos dentro de `W:\Sistemas\Clientes`.

Cómo elegir `UnitDepth`: ejecute primero con profundidad 1. Use profundidad 2 en contenedores grandes (`Clientes`, `Respaldos`, `Pedimentos`). La meta es tener entre 200 y 3,000 unidades, y que cada una sea **≤ 80 % de la capacidad de una noche** (≈ 0.9 TB a 50 MB/s). Así una unidad casi siempre termina dentro de una sola ventana.

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

**Reglas de clasificación (por unidad, con el *archivo* más reciente de todo el subárbol):**

| Condición | Nivel | Acción |
|---|---|---|
| `FutureDated > 0` (archivo con fecha futura: reloj erróneo o archivo descomprimido) | `Review` | Decidir manualmente |
| `NewestWrite < 2021-01-01` | `Cold` | Archivo histórico (2012–2020) |
| `ColdPct ≥ 80` y `SizeGB ≥ 50` | `Review` | Casi todo antiguo con pocos archivos recientes: elegir `Hot`, `Cold`, `Split` o `Exclude` |
| cualquier otro caso | `Hot` | Activo / FM2 |

Criterios para resolver las filas `Review`:

* `Hot`: mantiene el expediente completo. Es la opción por defecto para clientes activos.
* `Split`: copia a lo Caliente los archivos de 2021 en adelante y a lo Frío los anteriores, con robocopy `/MAXAGE:20210101` y `/MINAGE:20210101`. Úselo solo donde la integridad de la carpeta no importe (volcados de escaneos, exportaciones).
* `Exclude`: solo para duplicados comprobados y con aprobación por escrito (1.4). Las unidades excluidas quedan registradas en `jobs\excluded_units.csv`.

Puntos de atención:

* El LastWriteTime de una carpeta no es confiable (solo cambia cuando cambian sus hijos directos). Por eso el script usa la fecha del archivo más reciente del subárbol.
* Una unidad con `OldestWrite = NewestWrite` y muchos archivos normalmente indica que se copió con una herramienta que reinició las fechas. Clasifíquela por el nombre de la carpeta (por ejemplo `2016`).
* Robocopy (`/COPY:DAT`, `/DCOPY:DAT`) y `gcloud storage rsync` conservan las fechas de modificación. Por eso la clasificación se puede reproducir en el destino.

Para editar los niveles use PowerShell. Excel convierte la columna `Bytes` en `1.2E+12` al guardar y la corrompe:

```powershell
$f = 'C:\AGACE-Migration\inventory\summary_folders.csv'
$s = Import-Csv $f
$s | Where-Object { $_.Root -eq 'W:\Sistemas' -and $_.Unit -like 'Clientes\ACME*' } | ForEach-Object { $_.Tier = 'Hot' }
$s | Export-Csv $f -NoTypeInformation -Encoding UTF8
$s | Group-Object Tier | Select-Object Name, Count, @{n='TB';e={[math]::Round(($_.Group | Measure-Object Bytes -Sum).Sum/1e12,2)}}
```

### 1.4 Carpetas duplicadas entre G:\Seagate y W:\Sistemas

Es probable que G:\Seagate (4.29 TB) sea, al menos en parte, un respaldo de W:\Sistemas (4.89 TB). Los duplicados se confirman en tres niveles, todos ejecutados localmente en el origen y sin usar el enlace WAN:

| Nivel | Método | Costo |
|---|---|---|
| L1 Firma | Para cada carpeta ≥ 1 GB (profundidad ≤ 6): número de archivos + bytes totales + un hash, independiente del orden, del *nombre + tamaño* de cada archivo. Encuentra la copia aunque esté bajo otra carpeta padre, por ejemplo `G:\Seagate\Respaldo2019\Clientes` = `W:\Sistemas\Clientes`. | Solo lee el TSV, minutos |
| L2 `robocopy /L` | Confirma nombre + tamaño + **fecha** de cada par candidato. Código 0 = idéntico. | Metadatos, minutos |
| L3 Muestra SHA-256 | `09-Hash-Sample.ps1`: 200 archivos al azar + los 10 más grandes por par. Obligatorio para pares > 100 GB y para `SameNameSize-DifferentDate`. | Solo lee la muestra |

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
# Prueba de contenido L3 para un par (ambas unidades son locales)
.\09-Hash-Sample.ps1 -Root 'G:\Seagate\Respaldo2019\Clientes' -OutCsv C:\AGACE-Migration\inventory\hash_pair01_G.csv
.\09-Hash-Sample.ps1 -Root 'W:\Sistemas\Clientes' -SampleFrom C:\AGACE-Migration\inventory\hash_pair01_G.csv -OutCsv C:\AGACE-Migration\inventory\hash_pair01_W.csv
Compare-Object (Import-Csv C:\AGACE-Migration\inventory\hash_pair01_G.csv) (Import-Csv C:\AGACE-Migration\inventory\hash_pair01_W.csv) -Property RelPath, SHA256
# sin salida = APROBADO
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

**Decisión por cada par `Identical`:**

* **Estrategia A, sembrar dentro de GCP (recomendada, por defecto).** W: cruza la WAN una sola vez. Dentro de la VM se clona hacia el destino de G: (2.6). Después, el trabajo de G: encuentra todos los archivos "iguales" y casi no envía nada, y aun así la estructura de G: queda como copia 1:1 para los auditores. Guardar el duplicado en Archive cuesta alrededor de US$1.2 por TB al mes. Lo que se ahorra es tiempo de WAN, que es el recurso escaso.
* **Estrategia B, excluir.** Se pone la unidad de G: en el nivel `Exclude`. Ahorra tiempo de WAN y almacenamiento, pero la copia de G: no existirá en GCP. Requiere aprobación por escrito del área de cumplimiento de AGACE. `duplicates.csv` se conserva en el bucket de archivo (`_manifest/`) como evidencia.

Las coincidencias parciales (G: es una copia *más antigua* de una carpeta que ya cambió en W:) generan firmas distintas y se copian completas. Es una postura conservadora a propósito: un archivo borrado de producción puede sobrevivir solo en el disco de respaldo.

Bytes de WAN ahorrados = suma de `SizeGB` de los pares `Identical` utilizados (`D_dup` en la Sección 5). El mismo método sirve para comparar F:\Lacie contra W:\Sistemas: agregue `'F:\Lacie'` a `-FileListRoots` y ejecute con `-RootA 'F:\Lacie'`.

### 1.5 Generar la lista de trabajos

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
.\03-Build-Jobs.ps1     # imprime trabajos y TB por nivel -> anote TB Caliente / TB Frío en la Sección 5
```

Orden: lo Caliente antes que lo Frío. Dentro de cada nivel, el orden de unidades es D:, C:, W:, F:, G:. G: va al final para poder sembrar sus duplicados desde W:. Ponga en `Hold` las unidades de G: que formen parte de un par `Identical` hasta terminar la siembra (2.6):

```powershell
$d = Import-Csv C:\AGACE-Migration\inventory\duplicates.csv | Where-Object Verdict -eq 'Identical'
$jf = 'C:\AGACE-Migration\jobs\jobs.csv'; $j = Import-Csv $jf
foreach ($x in $j) { if ($d | Where-Object { $x.Source -like "$($_.PathA)*" -or $_.PathA -like "$($x.Source)\*" }) { $x.Status = 'Hold' } }
$j | Export-Csv $jf -NoTypeInformation -Encoding UTF8
```

**Compuerta 1, inventario aprobado:** `summary_folders.csv` no tiene filas `Review`; AGACE firmó la lista de carpetas de C:, los totales Caliente/Frío, las decisiones `Exclude` y la lista de BD/PST; `jobs.csv` ya está generado.

---

## 2. Robocopy: mapeo de cada unidad a su destino en GCP

### 2.1 Zona de aterrizaje en GCP (Cloud Shell, T-7 días)

```bash
PROJECT=agace-migracion; REGION=northamerica-south1; ZONE=northamerica-south1-a
gcloud config set project $PROJECT
gcloud services enable compute.googleapis.com storage.googleapis.com
gcloud compute networks create agace-vpc --subnet-mode=custom
gcloud compute networks subnets create agace-subnet-mx --network=agace-vpc --region=$REGION \
  --range=10.50.0.0/24 --enable-private-ip-google-access
# Salida a internet sin IP pública (Windows Update, descarga de PowerShell 7)
gcloud compute routers create agace-router --network=agace-vpc --region=$REGION
gcloud compute routers nats create agace-nat --router=agace-router --region=$REGION \
  --nat-all-subnet-ip-ranges --auto-allocate-nat-external-ips
# HA VPN (2 túneles + Cloud Router/BGP) hacia el firewall de Matamoros según la guía de Cloud VPN.
# En el firewall local: TCP MSS clamping a 1360 (evita fragmentación IPsec, que arruina el rendimiento SMB).
gcloud compute firewall-rules create agace-allow-smb-onprem --network=agace-vpc --direction=INGRESS \
  --action=ALLOW --rules=tcp:445 --source-ranges=192.168.10.20/32 --target-tags=agace-fs
gcloud compute firewall-rules create agace-allow-iap-rdp --network=agace-vpc --direction=INGRESS \
  --action=ALLOW --rules=tcp:3389 --source-ranges=35.235.240.0/20 --target-tags=agace-fs
gcloud iam service-accounts create sa-agace-fs --display-name="AGACE file server VM"
gcloud compute machine-types list --zones=$ZONE --filter="name=e2-standard-8"   # confirmar disponibilidad (N2 no existe en northamerica-south1)
gcloud compute instances create agace-gcp-fs01 --zone=$ZONE --machine-type=e2-standard-8 \
  --image-family=windows-2022 --image-project=windows-cloud --boot-disk-size=200GB --boot-disk-type=pd-balanced \
  --network-interface=subnet=agace-subnet-mx,private-network-ip=10.50.0.10,no-address \
  --tags=agace-fs --service-account=sa-agace-fs@$PROJECT.iam.gserviceaccount.com --scopes=cloud-platform \
  --create-disk=name=agace-hot,size=6000GB,type=pd-balanced,auto-delete=no \
  --create-disk=name=agace-cold-staging,size=8000GB,type=pd-standard,auto-delete=no
gcloud compute resource-policies create snapshot-schedule agace-daily-0600 --region=$REGION \
  --max-retention-days=14 --on-source-disk-delete=keep-auto-snapshots --daily-schedule --start-time=12:00
gcloud compute disks add-resource-policies agace-hot --resource-policies=agace-daily-0600 --zone=$ZONE
```

Dimensionamiento: `agace-hot = TB Caliente × 1.3` y `agace-cold-staging = TB Frío × 1.1`, con los totales de 1.5. Los discos persistentes pueden crecer en línea pero nunca reducirse, así que empiece con el tamaño calculado. El controlador de dominio debe ser accesible por la VPN para unir la VM al dominio (DNS 53, Kerberos 88, LDAP 389, SMB 445, RPC 135 + 49152-65535). El snapshot corre a las 12:00 UTC, que son las 06:00 en Matamoros (CST).

En la VM (RDP por IAP, como administrador de dominio):

```powershell
tzutil /s "Central Standard Time"          # debe coincidir con 'tzutil /g' de AGACE-FS01
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -Value 1
Add-Computer -DomainName agace.local -Credential (Get-Credential) -Restart
# después del reinicio - identificar los discos por SerialNumber (= nombre del disco) antes de formatear
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
gcloud version      # gcloud CLI viene preinstalado en las imágenes Windows de GCE; instale también PowerShell 7.4 LTS (MSI) para 07/08
```

NTFS con clúster de 4 KB (el valor por defecto) admite volúmenes de hasta 16 TB. Si el disco Caliente debe ser mayor, use `-AllocationUnitSize 8192` o más.

### 2.2 Mapa origen → destino

| Origen | Nivel | Destino robocopy (UNC desde AGACE-FS01) | Ruta en la VM | Ubicación final en GCS |
|---|---|---|---|---|
| `C:\<carpeta aprobada>` | Caliente | `\\agace-gcp-fs01.agace.local\Hot$\C_Datos\<carpeta>` | `E:\AGACE\Hot\C_Datos\…` | `gs://agace-operacion-activa/C_Datos/…` |
| `C:\<carpeta aprobada>` | Frío | `\\agace-gcp-fs01.agace.local\ColdStage$\C_Datos\<carpeta>` | `S:\AGACE\Cold\C_Datos\…` | `gs://agace-archivo-historico-2012-2020/C_Datos/…` |
| `D:\Informacion\<unidad>` | Caliente / Frío | `…\Hot$\D_Informacion\<unidad>` / `…\ColdStage$\D_Informacion\<unidad>` | `E:\AGACE\Hot\D_Informacion\…` / `S:\AGACE\Cold\D_Informacion\…` | `…/D_Informacion/…` |
| `F:\Lacie\<unidad>` | Caliente / Frío | `…\Hot$\F_Lacie\<unidad>` / `…\ColdStage$\F_Lacie\<unidad>` | `E:\…\F_Lacie` / `S:\…\F_Lacie` | `…/F_Lacie/…` |
| `G:\Seagate\<unidad>` | Caliente / Frío | `…\Hot$\G_Seagate\<unidad>` / `…\ColdStage$\G_Seagate\<unidad>` | `E:\…\G_Seagate` / `S:\…\G_Seagate` | `…/G_Seagate/…` |
| `W:\Sistemas\<unidad>` | Caliente / Frío | `…\Hot$\W_Sistemas\<unidad>` / `…\ColdStage$\W_Sistemas\<unidad>` | `E:\…\W_Sistemas` / `S:\…\W_Sistemas` | `…/W_Sistemas/…` |
| **Nunca se copia** | – | `C:\Windows`, `Program Files*`, `ProgramData`, `Users\*\AppData`, `$RECYCLE.BIN`, `System Volume Information`, `$WinREAgent`, `pagefile.sys`, `hiberfil.sys`, `swapfile.sys`, BD/PST en uso | – | – |

La ruta relativa bajo cada carpeta de unidad es la misma en E:, en S: y en ambos buckets. Cualquier archivo se puede rastrear del origen a la VM y a GCS con una sola ruta.

### 2.3 Conjunto estándar de parámetros

| Parámetro | Razón |
|---|---|
| `/E` | Recursivo, incluye carpetas vacías. **No `/MIR`** durante la migración. |
| `/COPY:DATSO` (Caliente) / `/COPY:DAT` (Frío) | Datos, atributos y fechas, más permisos NTFS y propietario en lo Caliente. GCS no puede guardar permisos NTFS, así que lo Frío no los copia. |
| `/DCOPY:DAT` | Conserva las fechas de las carpetas, que el proceso anual de envejecimiento necesita. |
| `/B` | Modo respaldo: lee los archivos sin importar sus permisos. Requiere proceso elevado y pertenecer a Backup Operators/Administradores. |
| `/MT:32` (`/MT:8` en F:/G:) | Los hilos compensan la latencia WAN con archivos pequeños. Menos hilos en discos USB mecánicos evitan saturarlos de búsquedas. |
| `/R:2 /W:5` | El valor por defecto de 1,000,000 reintentos × 30 s haría que un solo archivo bloqueado detuviera la noche. |
| `/XJ` | Omite junctions/enlaces simbólicos, lo que evita ciclos como "Application Data". |
| `/XD $RECYCLE.BIN "System Volume Information" $WinREAgent Config.Msi RECYCLER` | Carpetas ocultas del sistema, excluidas por nombre a cualquier profundidad. |
| `/XF pagefile.sys hiberfil.sys swapfile.sys Thumbs.db ~$*` | Archivos del sistema, miniaturas y archivos de bloqueo de Office. |
| `/RH:2200-0500 /PF` | Solo inicia archivos nuevos dentro de la ventana; se revisa archivo por archivo. |
| `/UNILOG:<archivo>` | Log Unicode, para que ñ/á/é en los nombres se lean bien. Un log por unidad. |
| `/NP /NDL /FP /BYTES` | Log compacto con rutas completas y bytes exactos. |
| *No se usa:* `/Z` | El modo reiniciable hace lenta la copia de muchos archivos pequeños. Un archivo interrumpido simplemente se recopia completo la noche siguiente. |
| *No se usa:* `/IPG` | No se puede combinar con `/MT`. Use el límite QoS de 4.4. |
| *No se usan:* `/MIR`, `/MOV`, `/PURGE` | `/PURGE` se usa solo en el corte, solo en lo Caliente y después de una vista previa con `/L` (2.5). |

### 2.4 Comandos exactos por unidad

El orquestador (2.5) genera estos comandos para cada unidad de migración. Las mismas líneas sirven para ejecutar a mano el piloto o repetir una unidad. No termine un origen entre comillas con diagonal invertida: robocopy interpreta `"D:\"` como `D:"`.

```bat
:: ===== Comunes (cmd.exe) =====
set HOT=\\agace-gcp-fs01.agace.local\Hot$
set COLD=\\agace-gcp-fs01.agace.local\ColdStage$
set LOG=C:\AGACE-Migration\logs\manual
set RC_COMMON=/DCOPY:DAT /B /R:2 /W:5 /XJ /NP /NDL /FP /BYTES /RH:2200-0500 /PF /XD "$RECYCLE.BIN" "System Volume Information" "$WinREAgent" "Config.Msi" "RECYCLER" /XF pagefile.sys hiberfil.sys swapfile.sys Thumbs.db "~$*"

:: ===== C: (solo carpetas de negocio aprobadas - ejemplo C:\Contabilidad, Caliente) =====
robocopy "C:\Contabilidad" "%HOT%\C_Datos\Contabilidad" /E /COPY:DATSO /MT:32 %RC_COMMON% /UNILOG:%LOG%\C_Contabilidad.log

:: ===== D:\Informacion (~232 GB) - unidad Caliente / unidad Fría =====
robocopy "D:\Informacion\<Unidad>" "%HOT%\D_Informacion\<Unidad>"  /E /COPY:DATSO /MT:32 %RC_COMMON% /UNILOG:%LOG%\D_<Unidad>.log
robocopy "D:\Informacion\<Unidad>" "%COLD%\D_Informacion\<Unidad>" /E /COPY:DAT   /MT:32 %RC_COMMON% /UNILOG:%LOG%\D_<Unidad>.log

:: ===== F:\Lacie (~1.15 TB, USB: 8 hilos) =====
robocopy "F:\Lacie\<Unidad>" "%HOT%\F_Lacie\<Unidad>"  /E /COPY:DATSO /MT:8 %RC_COMMON% /UNILOG:%LOG%\F_<Unidad>.log
robocopy "F:\Lacie\<Unidad>" "%COLD%\F_Lacie\<Unidad>" /E /COPY:DAT   /MT:8 %RC_COMMON% /UNILOG:%LOG%\F_<Unidad>.log

:: ===== G:\Seagate (~4.29 TB, USB: 8 hilos; después de la siembra 2.6) =====
robocopy "G:\Seagate\<Unidad>" "%HOT%\G_Seagate\<Unidad>"  /E /COPY:DATSO /MT:8 %RC_COMMON% /UNILOG:%LOG%\G_<Unidad>.log
robocopy "G:\Seagate\<Unidad>" "%COLD%\G_Seagate\<Unidad>" /E /COPY:DAT   /MT:8 %RC_COMMON% /UNILOG:%LOG%\G_<Unidad>.log

:: ===== W:\Sistemas (~4.89 TB) =====
robocopy "W:\Sistemas\<Unidad>" "%HOT%\W_Sistemas\<Unidad>"  /E /COPY:DATSO /MT:32 %RC_COMMON% /UNILOG:%LOG%\W_<Unidad>.log
robocopy "W:\Sistemas\<Unidad>" "%COLD%\W_Sistemas\<Unidad>" /E /COPY:DAT   /MT:32 %RC_COMMON% /UNILOG:%LOG%\W_<Unidad>.log

:: ===== Unidad de archivos sueltos (Recurse=False): solo archivos de la carpeta, SIN /E =====
robocopy "W:\Sistemas\Clientes" "%HOT%\W_Sistemas\Clientes" /COPY:DATSO /MT:32 %RC_COMMON% /UNILOG:%LOG%\W_Clientes_files.log

:: ===== Unidad Split: mismo origen, dos comandos =====
robocopy "W:\Sistemas\<Unidad>" "%HOT%\W_Sistemas\<Unidad>"  /E /COPY:DATSO /MAXAGE:20210101 /MT:32 %RC_COMMON% /UNILOG:%LOG%\W_<Unidad>_hot.log
robocopy "W:\Sistemas\<Unidad>" "%COLD%\W_Sistemas\<Unidad>" /E /COPY:DAT   /MINAGE:20210101 /MT:32 %RC_COMMON% /UNILOG:%LOG%\W_<Unidad>_cold.log

:: ===== Sincronización diaria (igual que el baseline Caliente, ventana 23:59-04:00) =====
::   reemplace /RH:2200-0500 por /RH:2359-0400 en RC_COMMON

:: ===== Verificación (no copia): código 0 = destino idéntico, 2 = solo sobrantes en destino =====
robocopy "W:\Sistemas\<Unidad>" "%HOT%\W_Sistemas\<Unidad>" /E /L /COPY:DATSO /MT:32 %RC_COMMON% /UNILOG:%LOG%\W_<Unidad>_verify.log

:: ===== Solo en el corte y solo Caliente: vista previa de borrados, revisar líneas *EXTRA y luego ejecutar sin /L =====
robocopy "W:\Sistemas\<Unidad>" "%HOT%\W_Sistemas\<Unidad>" /E /PURGE /L /COPY:DATSO /MT:32 %RC_COMMON% /UNILOG:%LOG%\W_<Unidad>_purge_preview.log
```

**Piloto, Compuerta P (T-3 días).** Elija dos conjuntos reales en W: de unos 20 GB cada uno: (a) archivos grandes (> 100 MB) y (b) carpetas con PDF/XML pequeños (≥ 50,000 archivos). Después:

```powershell
$dst = '\\agace-gcp-fs01.agace.local\Hot$\_pilot'
foreach ($t in @(@('large', 'W:\Sistemas\<PilotoGrande>'), @('small', 'W:\Sistemas\<PilotoPequeno>'))) {
  $m = Get-ChildItem -LiteralPath $t[1] -Recurse -File -Force | Measure-Object Length -Sum
  $s = Measure-Command { robocopy $t[1] "$dst\$($t[0])" /E /COPY:DAT /MT:32 /R:2 /W:5 /XJ /NP /NFL /NDL /UNILOG:"C:\AGACE-Migration\logs\pilot_$($t[0]).log" }
  '{0}: {1:N0} archivos, {2:N2} GB, {3:N0} s => {4:N1} MB/s, {5:N0} archivos/s' -f $t[0], $m.Count, ($m.Sum/1e9), $s.TotalSeconds, ($m.Sum/1e6/$s.TotalSeconds), ($m.Count/$s.TotalSeconds)
}
Get-SmbConnection | Format-Table ServerName, ShareName, Dialect    # se espera 3.x
```

Use el resultado (`R_eff` de "large", `F_rate` de "small") en la Sección 5. Repita una vez con `/MT:64` y conserve la opción más rápida. Al terminar, borre `_pilot` en la VM.

### 2.5 Orquestador: `04-Run-Robocopy.ps1`

El orquestador lee `jobs.csv` y ejecuta hasta 4 unidades en paralelo, nunca dos en el mismo disco físico. Respeta la ventana y termina las unidades que sigan corriendo 15 minutos después del cierre; esas quedan como `Partial` y se repiten la noche siguiente. Registra el estado y el código de salida de cada unidad.

Estados de una unidad: `Pending → Running → Done → Verified`. `Failed`, `Fatal`, `Partial` y `NotVerified` se retoman en el siguiente Baseline. `Hold` espera la siembra.

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
.\04-Run-Robocopy.ps1 -Mode Baseline                       # tarea 01-Baseline (22:00-05:00)
.\04-Run-Robocopy.ps1 -Mode Delta                          # tarea 02-DailySync (23:59-04:00), unidades Calientes ya copiadas
.\04-Run-Robocopy.ps1 -Mode Verify -Window 0000-2359       # fin de semana / evidencia de Compuertas H y A (/L, no copia)
.\04-Run-Robocopy.ps1 -Mode Verify -Reverify -Purge -Tier Hot -Window 0000-2359   # corte: vista previa de borrados
.\04-Run-Robocopy.ps1 -Mode Delta  -Purge -Window 0000-2359                       # corte: sincronización final con borrados
Import-Csv C:\AGACE-Migration\jobs\jobs.csv | Group-Object Tier, Status | Select-Object Name, Count
```

### 2.6 Siembra de duplicados de G: dentro de GCP

Ejecute esto el día en que la última unidad Fría de W: llegue a `Done`, antes de liberar cualquier unidad de G: de `Hold`:

```powershell
# AGACE-FS01
.\02-Find-Duplicates.ps1                      # reconfirmar con robocopy /L: los datos pudieron cambiar desde el inventario
.\10-Build-SeedScript.ps1
Copy-Item C:\AGACE-Migration\jobs\seed-on-vm.ps1 '\\agace-gcp-fs01.agace.local\ColdStage$\_control\'
# VM (elevado): copia local disco a disco, sin WAN
powershell -NoProfile -ExecutionPolicy Bypass -File S:\AGACE\Cold\_control\seed-on-vm.ps1
# AGACE-FS01: liberar las unidades de G: en espera
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

El script solo siembra pares cuyo lado de W: sea totalmente Frío. Una carpeta Caliente de W: pudo recibir archivos nuevos después del inventario, y la siembra pondría en G: archivos que nunca existieron ahí. Después de ejecutar los trabajos de G:, `Verify` debe devolver código 0 en las unidades sembradas.

### 2.7 Códigos de salida y errores frecuentes

| Código robocopy | Significado | Estado en el orquestador |
|---|---|---|
| 0 | Nada que copiar (ya idéntico) | Done / Verified |
| 1 | Archivos copiados correctamente | Done |
| 2 | Archivos sobrantes en destino (borrados en el origen después de copiarse) | Done / Verified |
| 3, 5, 6, 7 | Combinaciones de los anteriores / diferencias | Done (revisar log) |
| 8–15 | Algunos archivos fallaron tras los reintentos | Failed: se repite la noche siguiente |
| ≥ 16 | Error fatal (ruta, permisos o sintaxis) | Fatal: corregir antes de la noche siguiente |

| Error en el log | Causa | Acción |
|---|---|---|
| `ERROR 5` Acceso denegado | Proceso no elevado, `/B` sin privilegios | Revisar RunLevel Highest de la tarea y la membresía en Backup Operators |
| `ERROR 32` Archivo en uso | Abierto por un usuario o aplicación | Lo toma la sincronización diaria. Las BD van por respaldo nativo |
| `ERROR 53` / `ERROR 64` El nombre de red ya no está disponible | Caída de VPN o ISP | Sección 6.2 |
| `ERROR 112` Espacio insuficiente | Disco persistente lleno | `gcloud compute disks resize agace-hot --size=<GB> --zone=…` y luego `Resize-Partition` en la VM |
| `ERROR 21` El dispositivo no está listo | Disco USB dormido o desconectado | Revisar energía y cable. Si se repite, Sección 6.3 |
| `ERROR 23` CRC / `ERROR 1117` Error de E/S | **El disco origen está fallando** | **DETENER esa unidad de inmediato.** Sección 6.3 |
| `ERROR 1314` Privilegio no disponible | Asignar propietario (O) en la VM | Agregar la cuenta a Backup Operators en la VM |

```powershell
# Histograma de errores de la noche anterior (patrón independiente del idioma)
Select-String -Path C:\AGACE-Migration\logs\Baseline\*\*.log -Pattern 'ERROR (\d+) \(0x' |
  ForEach-Object { $_.Matches[0].Groups[1].Value } | Group-Object | Sort-Object Count -Descending | Format-Table Name, Count
```

---

## 3. Google Cloud Storage: buckets, ciclo de vida y retención

### 3.1 Cómo funciona el ciclo de vida (y por qué el diseño no es "edad > 5 años")

* La condición `age` del ciclo de vida cuenta los días desde que el objeto se **creó en el bucket**, no desde el LastWriteTime del archivo. Un pedimento de 2013 subido en noviembre de 2026 tiene `age = 0`, así que una regla simple "age ≥ 1825 días → Archive" dejaría todo el histórico en Standard hasta 2031.
* Por eso el diseño hace tres cosas:
  1. Lo Frío (2012–2020) se escribe directo en un bucket cuya **clase por defecto es ARCHIVE**. No hay transición, ni costo Standard, ni operaciones de cambio de clase.
  2. A los objetos Calientes se les asigna un **Custom-Time** igual al mes del LastWriteTime del archivo (script 08). Las reglas usan `daysSinceCustomTime`.
  3. Las reglas `age` quedan como respaldo para objetos sin Custom-Time, es decir, archivos creados después del corte, donde la fecha de subida ≈ fecha del documento.
* Las condiciones dentro de una regla se combinan con Y, y las reglas separadas con O. Si varias reglas SetStorageClass aplican a la vez, GCS aplica la de la clase más barata. Las acciones pueden tardar hasta 24 h en aplicarse.
* Duración mínima de almacenamiento: Nearline 30 días, Coldline 90 días, Archive 365 días. Si se borra antes, se cobra como si se hubiera guardado el mínimo.
* **Todas las clases devuelven los datos en milisegundos.** No hay una "restauración" tipo cinta, así que Archive cumple el requisito de "consulta inmediata para auditoría". La lectura tiene un costo por GB: aproximadamente US$0.02/GB en Coldline y US$0.05/GB en Archive (precio de lista; verifique en la calculadora de precios para `northamerica-south1`).

| Datos | Ubicación | Clase | Transiciones |
|---|---|---|---|
| Caliente (archivo más reciente ≥ 2021) | VM E: + `gs://agace-operacion-activa` | STANDARD | → COLDLINE a los 5 años (1826 días) de la fecha del documento → ARCHIVE a los 7 años (2557 días) |
| Frío 2012–2020 | `gs://agace-archivo-historico-2012-2020` | ARCHIVE desde el día 0 | ninguna |
| Versiones anteriores (archivos sobrescritos o borrados en la VM) | `gs://agace-operacion-activa` | → COLDLINE a los 30 días | se borran 5 años después de dejar de ser actuales (**confirmar con cumplimiento**) |

Se usa Coldline en los años 5 a 7 porque ahí se concentran las auditorías tardías y los plazos ampliados, y su costo de lectura es menos de la mitad que el de Archive. Si AGACE prefiere Archive desde el año 5, cambie `COLDLINE` por `ARCHIVE` en las dos primeras reglas.

### 3.2 Crear los buckets

```bash
gcloud storage buckets create gs://agace-operacion-activa --location=northamerica-south1 \
  --default-storage-class=STANDARD --uniform-bucket-level-access --public-access-prevention
gcloud storage buckets update gs://agace-operacion-activa --versioning
gcloud storage buckets create gs://agace-archivo-historico-2012-2020 --location=northamerica-south1 \
  --default-storage-class=ARCHIVE --uniform-bucket-level-access --public-access-prevention
```

El bucket Caliente **no** lleva política de retención, a propósito. Una política de retención impide sobrescribir o borrar objetos recientes, y la sincronización nocturna de archivos editados fallaría. En su lugar, lo protegen el versionado y las reglas para versiones anteriores.

### 3.3 Reglas de ciclo de vida (bucket Caliente)

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
gcloud storage buckets describe gs://agace-operacion-activa      # revisar lifecycle_config, versionado y clase por defecto
gcloud storage buckets describe gs://agace-archivo-historico-2012-2020
```

### 3.4 Política de retención (bucket de archivo), solo después de la Compuerta A

```bash
# Solo cuando todas las unidades Frías estén subidas y verificadas (Compuerta A). Si no, una carga errónea queda congelada 5 años.
gcloud storage buckets update gs://agace-archivo-historico-2012-2020 --retention-period=1826d
# IRREVERSIBLE. Solo con aprobación por escrito de la dirección de AGACE y de los asesores de cumplimiento (A7).
gcloud storage buckets update gs://agace-archivo-historico-2012-2020 --lock-retention-period
```

El plazo de retención corre para cada objeto desde su subida. Una vez bloqueado, el periodo puede aumentarse pero nunca reducirse, y el bucket no puede eliminarse mientras contenga objetos protegidos.

### 3.5 IAM, registros de auditoría y seguridad

```bash
SA=sa-agace-fs@agace-migracion.iam.gserviceaccount.com
gcloud storage buckets add-iam-policy-binding gs://agace-operacion-activa --member=serviceAccount:$SA --role=roles/storage.objectAdmin
gcloud storage buckets add-iam-policy-binding gs://agace-archivo-historico-2012-2020 --member=serviceAccount:$SA --role=roles/storage.objectAdmin
# Después de la Compuerta A: la VM queda en solo lectura sobre el archivo; los auditores obtienen lectura
gcloud storage buckets remove-iam-policy-binding gs://agace-archivo-historico-2012-2020 --member=serviceAccount:$SA --role=roles/storage.objectAdmin
gcloud storage buckets add-iam-policy-binding gs://agace-archivo-historico-2012-2020 --member=serviceAccount:$SA --role=roles/storage.objectViewer
gcloud storage buckets add-iam-policy-binding gs://agace-archivo-historico-2012-2020 --member=group:auditoria@agace.com.mx --role=roles/storage.objectViewer
```

* Active los registros de acceso a datos (Data Access audit logs) de Cloud Storage (Data Read y Data Write) en IAM y administración → Registros de auditoría. Así queda registrada cada descarga de auditoría.
* La VM no tiene IP pública. RDP entra solo por IAP, SMB 445 está abierto solo para AGACE-FS01, y ambos buckets tienen Public Access Prevention.
* Antes de UploadCold, haga un análisis antimalware del disco temporal: `Start-MpScan -ScanType CustomScan -ScanPath S:\AGACE\Cold`. Nada infectado debe entrar a un archivo inmutable. El análisis en tiempo real de `E:\AGACE` y `S:\AGACE` puede pausarse durante el baseline solo con aprobación de seguridad, y debe reactivarse en el corte.

### 3.6 Carga de los buckets desde la VM

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
pwsh -File E:\AGACE\scripts\07-VM-Gcs.ps1 -Mode SyncHot       # diario 05:30 (tarea VM-SyncHot)
pwsh -File E:\AGACE\scripts\07-VM-Gcs.ps1 -Mode UploadCold    # diario 06:00, solo unidades Frías Verified
pwsh -File E:\AGACE\scripts\07-VM-Gcs.ps1 -Mode Verify        # evidencia para Compuertas H y A
```

`gcloud storage` valida sumas de verificación al subir. En la salida de `Verify`, lo Frío debe mostrar `Match = True` en todas las carpetas. En lo Caliente es normal que `GcsObjects ≥ LocalFiles`, porque los archivos borrados o renombrados permanecen en el bucket por diseño.

Los nombres de objeto en GCS tienen un límite de 1,024 bytes (UTF-8). Revíselo antes de la primera carga:

```powershell
Get-ChildItem E:\AGACE\Hot, S:\AGACE\Cold -Recurse -File -Force | Where-Object { [Text.Encoding]::UTF8.GetByteCount($_.FullName) -gt 1000 } | Select-Object FullName
```

**Marcado de Custom-Time (una sola vez, en la Compuerta H, después del primer SyncHot completo):**

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
# 1) Prueba de codificación con UN nombre acentuado (fecha reciente para que el objeto no cambie de clase)
New-Item -ItemType Directory E:\AGACE\Hot\_prueba -Force | Out-Null
Set-Content -LiteralPath 'E:\AGACE\Hot\_prueba\Pedimento_Año_Señal.txt' -Value 'test'
pwsh -File E:\AGACE\scripts\07-VM-Gcs.ps1 -Mode SyncHot
'gs://agace-operacion-activa/_prueba/Pedimento_Año_Señal.txt' | Set-Content E:\AGACE\ct-test.txt -Encoding utf8NoBOM
$env:PYTHONUTF8 = '1'; cmd /c "gcloud storage objects update --read-paths-from-stdin --custom-time=2025-01-01T00:00:00Z < E:\AGACE\ct-test.txt"
gcloud storage objects describe "gs://agace-operacion-activa/_prueba/Pedimento_Año_Señal.txt"   # custom_time debe aparecer
# 2) Simulación y luego ejecución real
pwsh -File E:\AGACE\scripts\08-VM-Stamp-CustomTime.ps1 -WhatIf
pwsh -File E:\AGACE\scripts\08-VM-Stamp-CustomTime.ps1
```

Después del marcado, los objetos cuyo mes de documento tenga más de 5 años pasan a COLDLINE (y los de más de 7 años a ARCHIVE) en unas 24 h. Es la política funcionando como se diseñó. Los nombres que contienen `* ? [ ]` no pueden marcarse mediante URL con comodines. Quedan listados en `skipped-wildcard-names.txt` y se rigen por las reglas `age`.

### 3.7 Procedimiento de consulta para auditoría (requerimiento SAT / ANAM)

1. Localizar el archivo. Los manifiestos (`summary_folders.csv`, `files_*.tsv`, `jobs.csv`, `duplicates.csv` y los logs de robocopy comprimidos) se suben en la Compuerta A a `gs://agace-archivo-historico-2012-2020/_manifest/`, donde quedan protegidos por la misma retención.
2. Buscar por número de pedimento o cliente y copiar la carpeta a una carpeta de auditoría en la VM, que está dentro de GCP y por eso no genera cargo de salida:

```powershell
gcloud storage ls "gs://agace-archivo-historico-2012-2020/W_Sistemas/**/*3001234*"
gcloud storage cp --recursive "gs://agace-archivo-historico-2012-2020/W_Sistemas/<ruta>" "E:\AGACE\Auditoria\SAT-2026-001\"
```

3. Un expediente de 10 GB está disponible en minutos y cuesta alrededor de US$0.50 de lectura en Archive. Solo hay cargo de salida de red si se descarga fuera de GCP. Los auditores con `objectViewer` también pueden descargar desde la consola de Cloud.

### 3.8 Modelo de costos (ilustrativo; reemplace con los totales de 1.5 y los precios vigentes de la región)

| Concepto | Tamaño de ejemplo | Precio de lista aprox. / GB-mes | Mensual |
|---|---|---|---|
| Disco VM `agace-hot` (pd-balanced) | 5,200 GB | US$0.10 | ≈ US$520 |
| Bucket activa (Standard) | 4,000 GB | US$0.020 | ≈ US$80 |
| Bucket histórico (Archive) | 7,000 GB | US$0.0012 | ≈ US$8 |
| VM `e2-standard-8`, 24/7 (cómputo) | 8 vCPU | – | ≈ US$213 |
| Licencia de Windows Server (por vCPU-hora) | 8 vCPU | – | ≈ US$269 |
| Disco de arranque (pd-balanced) | 200 GB | US$0.109 | ≈ US$22 |
| Snapshots diarios de `agace-hot`, 14 días (depende del cambio diario) | ≈ 4.6 TB usados | – | ≈ US$230–300 |
| Túnel Classic VPN + IP, Cloud NAT | – | – | ≈ US$45 |
| *Comparación: los mismos 7 TB Fríos en pd-balanced* | 7,000 GB | US$0.10 | *≈ US$700* |
| `agace-cold-staging` temporal (pd-standard), hasta la Compuerta A | 8,000 GB | US$0.04 | ≈ US$320, prorrateado |

Con la VM, la licencia, los snapshots y la VPN, el total es de aprox. US$1,840–1,920/mes durante la migración y US$1,520–1,600 después de la Compuerta A (precios de lista; ver `docs/GCP_Setup_Guide_EN.md` M.1 para opciones de ahorro).

La mayor parte del ahorro viene de no mantener los datos Fríos en discos de VM. Optimizar la clase de GCS es un efecto secundario.

---

## 4. Programador de tareas de Windows: sincronización nocturna de varias unidades

### 4.1 Cuenta de servicio

`AGACE\svc-migration` (o una gMSA) necesita, solo mientras dure la migración:

* Administradores locales en AGACE-FS01, porque `/B`, RunLevel Highest y la escritura en el registro de eventos lo requieren;
* Backup Operators en la VM, y Control total en los recursos `Hot$` y `ColdStage$`;
* "Iniciar sesión como proceso por lotes".

Retire estos permisos 30 días después del corte.

### 4.2 Línea de tiempo nocturna

| Hora (Matamoros) | Equipo | Tarea | Comportamiento |
|---|---|---|---|
| 21:55 | FS01 | `\AGACE\03-Monitor` | Mide los bytes de la tarjeta de red cada 60 s hasta las 05:05; al final escribe la proyección |
| 22:00 | FS01 | `\AGACE\01-Baseline` | Unidades Pending/Failed/Partial; ningún archivo nuevo después de las 05:00; termina procesos a las 05:15; límite de la tarea 7 h 30 min |
| 23:59 | FS01 | `\AGACE\02-DailySync` | Sincronización del trabajo diario de las unidades Calientes ya copiadas (máx. 2 en paralelo); ningún archivo nuevo después de las 04:00; termina a las 04:15 |
| 05:30 | VM | `\AGACE\VM-SyncHot` | E: → bucket Caliente (dentro de GCP, sin WAN) |
| 06:00 | VM | `\AGACE\VM-UploadCold` | Unidades Frías Verified → bucket de archivo |
| 06:00 | GCP | Snapshot `agace-daily-0600` | Disco `agace-hot`, 14 días |
| 07:30 | Operación | Revisión matutina | Sección 5.5 |

La sincronización diaria de 23:59 a 04:00 corre **dentro** de la ventana de baseline de 22:00 a 05:00, y ambas comparten el enlace. Si el baseline se pausara durante la sincronización, quedarían solo ~3 h por noche para el baseline y los 11.2 TB serían imposibles (5.3). Por eso corren al mismo tiempo.

Ajustes de la tarea que importan:

* `Priority 4`: el valor por defecto de 7 da prioridad de CPU *y* de E/S por debajo de lo normal, y hace notablemente más lento a robocopy.
* `MultipleInstances IgnoreNew`.
* `StartWhenAvailable` desactivado, para que una noche perdida nunca arranque a las 09:00 en horario de oficina.

### 4.3 Registrar las tareas del servidor origen

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
# Prueba fuera de la ventana: debe terminar en ~15 s con "0 units run" (nunca copia fuera de su ventana)
Start-ScheduledTask -TaskPath '\AGACE\' -TaskName '01-Baseline'
Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='AGACE-Migration'} -MaxEvents 5 | Format-List TimeCreated, Id, Message
```

### 4.4 Límite opcional de ancho de banda (QoS) para proteger la operación nocturna

Si el mismo enlace lleva tráfico de la operación nocturna (VUCEM, validación de pedimentos, telefonía IP), limite a robocopy en lugar de usar `/IPG`:

```powershell
New-NetQosPolicy -Name 'AGACE-Robocopy-Cap' -AppPathNameMatchCondition 'robocopy.exe' -ThrottleRateActionBitsPerSecond 400000000   # 400 Mbps
Get-NetQosPolicy -Name 'AGACE-Robocopy-Cap'
Remove-NetQosPolicy -Name 'AGACE-Robocopy-Cap' -Confirm:$false      # cuando ya no se necesite
```

### 4.5 Tareas en la VM

```powershell
$pw  = 'C:\Program Files\PowerShell\7\pwsh.exe'
$set = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 12) -MultipleInstances IgnoreNew -Priority 4
$a1  = New-ScheduledTaskAction -Execute $pw -Argument '-NoProfile -File E:\AGACE\scripts\07-VM-Gcs.ps1 -Mode SyncHot'
$a2  = New-ScheduledTaskAction -Execute $pw -Argument '-NoProfile -File E:\AGACE\scripts\07-VM-Gcs.ps1 -Mode UploadCold'
Register-ScheduledTask -TaskPath '\AGACE\' -TaskName 'VM-SyncHot'    -Action $a1 -Trigger (New-ScheduledTaskTrigger -Daily -At 05:30) -Settings $set -User 'NT AUTHORITY\SYSTEM' -RunLevel Highest
Register-ScheduledTask -TaskPath '\AGACE\' -TaskName 'VM-UploadCold' -Action $a2 -Trigger (New-ScheduledTaskTrigger -Daily -At 06:00) -Settings $set -User 'NT AUTHORITY\SYSTEM' -RunLevel Highest
```

SYSTEM se autentica en GCS con la cuenta de servicio de la VM a través del servidor de metadatos. Si `hot-*.log` muestra "Permission denied" en archivos cuyos permisos copiados excluyen a SYSTEM, otorgue lectura solo sobre la copia destino: `icacls E:\AGACE\Hot /grant "SYSTEM:(OI)(CI)RX" /T /C`.

### 4.6 Después del corte

```powershell
Get-ScheduledTask -TaskPath '\AGACE\' | Disable-ScheduledTask        # en AGACE-FS01
# En la VM, VM-SyncHot se queda de forma permanente; muévala a la 01:00 porque ahora los usuarios trabajan en la VM
Set-ScheduledTask -TaskPath '\AGACE\' -TaskName 'VM-SyncHot' -Trigger (New-ScheduledTaskTrigger -Daily -At 01:00)
Disable-ScheduledTask -TaskPath '\AGACE\' -TaskName 'VM-UploadCold'  # después de la Compuerta A
```

---

## 5. Compuertas de verificación y cálculo de ancho de banda

### 5.1 Unidades de medida

El Explorador de Windows muestra "TB" pero en realidad son **TiB** (2⁴⁰ bytes). **11.2 "TB" = 11.2 TiB = 12.31 TB decimales = 12,314,530 MB.** Las velocidades de enlace son decimales. 1 MB/s = 8 Mbps. Todas las fórmulas siguientes usan MB decimales.

### 5.2 Fórmulas

| Símbolo | Definición |
|---|---|
| `D_wan` | Bytes que deben cruzar la WAN = TB Caliente + TB Frío (de 1.5) − `D_dup` (duplicados sembrados, 1.4) |
| `N` | Número de archivos a transferir (de `summary_folders.csv`) |
| `η` | Eficiencia de protocolo (IPsec + TCP + SMB3), 0.75–0.85; se mide en el piloto |
| `R_eff` | Rendimiento efectivo (MB/s) = `L_Mbps × η / 8`, o medido directamente en la prueba "large" del piloto |
| `F_rate` | Archivos por segundo medidos en la prueba "small" del piloto (limitado por latencia, hilos y disco) |
| `W` | Horas de ventana por noche (baseline = 7) |
| `U` | Aprovechamiento de la ventana = 0.9 (arranque de trabajos, cola, archivo en curso a las 05:00) |

```
Tiempo de transferencia (conservador)  T  = D_wan / R_eff  +  N / F_rate                  [s]
Capacidad por noche                    C  = R_eff × W × 3600 × U                          [MB/noche]
Noches necesarias                      Nn = T / (W × 3600 × U)
Rendimiento requerido para 10 noches   R_req = D_wan / (10 × W × 3600 × U)                [MB/s]
Enlace requerido                       L_req = R_req × 8 / η                              [Mbps]
Ajuste de la sincronización diaria     T_delta = N_hot / S_scan + ΔD_dia / R_eff  ≤  4.0 h × 0.85
   S_scan = archivos/s de una corrida Verify (/L) sobre lo Caliente; ΔD_dia = bytes modificados por día
```

### 5.3 Ejemplo resuelto: 11.2 TiB completos, sin deduplicación (peor caso)

* Segundos disponibles: `10 × 7 × 3600 × 0.9 = 226,800 s`
* `R_req = 12,314,530 MB / 226,800 s = 54.3 MB/s = 434 Mbps sostenidos`
* Con η = 0.8: **`L_req ≈ 543 Mbps`** de ancho de banda nocturno dedicado.
* Si el baseline se pausara durante la sincronización de 23:59 a 04:00, quedarían solo ~2.98 h por noche: `R_req = 127.4 MB/s ≈ 1,019 Mbps` sostenidos (enlace de ≈ 1.27 Gbps). Eso no se logra con una línea de 1 Gbps, y por eso el diseño es concurrente.

| Enlace (Mbps) | R_eff con η 0.8 (MB/s) | TB por noche (7 h, U 0.9) | Noches para 11.2 TiB | Noches para 8.2 TiB (con 3 TiB deduplicados) | Noches solo para 4 TB Calientes |
|---|---|---|---|---|---|
| 100 | 10 | 0.23 | 54.3 | 39.8 | 17.6 |
| 200 | 20 | 0.45 | 27.1 | 19.9 | 8.8 |
| 300 | 30 | 0.68 | 18.1 | 13.3 | 5.9 |
| 500 | 50 | 1.13 | 10.9 | 8.0 | 3.5 |
| 750 | 75 | 1.70 | 7.2 | 5.3 | 2.4 |
| 1000 | 100 | 2.27 | 5.4 | 4.0 | 1.8 |

Sume el término de archivos pequeños. Ejemplo: 3,000,000 archivos a 150 archivos/s medidos dan `3e6 / 150 = 20,000 s ≈ 5.6 h` (≈ 0.9 noches) adicionales al tiempo por bytes.

**Lo que esto significa para AGACE:**

* Con menos de ~550 Mbps sostenidos, los 11.2 TB completos no terminan en 10 noches.
* Con 300 Mbps, solo lo Caliente (ejemplo: 4 TB) termina en ~6 noches. El corte puede hacerse en la fecha prevista y lo Frío sigue cargándose las noches siguientes sin afectar a FM2.
* Eliminar duplicados y los datos del sistema operativo en C: reduce `D_wan` directamente.

### 5.4 Compuerta P: resultado del piloto contra el plan

Registre `R_eff`, `F_rate`, el dialecto SMB y el RTT (`Test-NetConnection agace-gcp-fs01.agace.local -Port 445` además de `ping`). Calcule `Nn` con los totales reales de Caliente y Frío.

* `Nn(todo) ≤ 9`: SE AUTORIZA el plan completo.
* `Nn(Caliente) ≤ 9` pero `Nn(todo) > 9`: SE AUTORIZA con "primero lo Caliente, lo Frío después del corte". Informe a la dirección la nueva fecha de término de lo Frío.
* `Nn(Caliente) > 9`: NO SE AUTORIZA. Amplíe el ancho de banda temporalmente, agregue ventanas diurnas de fin de semana (sáb 14:00 – lun 05:00, si AGACE no opera) o reduzca el alcance.

### 5.5 Monitoreo nocturno

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

Revisión matutina (07:30, ~10 minutos):

```powershell
Import-Csv C:\AGACE-Migration\monitor\projection.csv | Select-Object -Last 1 | Format-List
Import-Csv C:\AGACE-Migration\jobs\jobs.csv | Group-Object Tier, Status | Select-Object Name, Count
Get-ChildItem C:\AGACE-Migration\logs\Baseline | Sort-Object Name | Select-Object -Last 1 | ForEach-Object { Import-Csv "$($_.FullName)\summary.csv" } | Where-Object Status -ne 'Done' | Format-Table
Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='AGACE-Migration'; StartTime=(Get-Date).AddHours(-12)} | Format-Table TimeCreated, Id, LevelDisplayName -AutoSize
# En la VM: espacio libre
Get-Volume -DriveLetter E, S | Format-Table DriveLetter, @{n='FreeGB';e={[math]::Round($_.SizeRemaining/1GB)}}, @{n='SizeGB';e={[math]::Round($_.Size/1GB)}}
```

| Estado (proyección) | Regla | Acción |
|---|---|---|
| GREEN (verde) | `NightsNeededAll ≤ NightsLeft − 1` | Continuar |
| AMBER (ámbar) | Solo cabe lo Caliente (`NightsNeededHot ≤ NightsLeft − 1`) | Primero lo Caliente: Baseline con `-Tier Hot` esta noche. Lo Frío continúa después del corte |
| RED (rojo) | Lo Caliente no cabe | Escalar el mismo día: palancas de la Sección 6.2, cambiar la fecha de corte |
| Evento 1101 | < 70 % de los MB/s planeados durante 30 min | Sección 6.2 |

El contador de la tarjeta de red mide todo el tráfico que envía el servidor. Normalmente las noches están tranquilas. Si un respaldo externo también corre de noche, reprográmelo durante la migración.

### 5.6 Compuertas

| Compuerta | Cuándo | Criterio de aprobación | Evidencia |
|---|---|---|---|
| G0 Revisión previa | T-7 | Discos sanos, ajustes de energía aplicados, VPN activa, VM en el dominio, recursos accesibles desde FS01 | Salida de 1.1, `Test-NetConnection … -Port 445` = True |
| G1 Inventario | T-5 | Sin filas `Review`; aprobados la lista de C:, los totales Caliente/Frío, la lista Exclude y la lista de BD/PST | `summary_folders.csv` firmado, `jobs.csv` |
| GP Piloto | T-3 | Proyección según 5.4 = SE AUTORIZA | Salida del piloto, hoja de cálculo |
| GN Nocturna (N1…N10) | 07:30 diario | Sin `Fatal`; `Failed` < 1 % de las unidades; proyección GREEN/AMBER | `summary.csv`, `projection.csv`, eventos |
| GH Caliente completo | Antes del corte | Todas las unidades Calientes `Verified` (código 0/2); muestra de hash sin diferencias en ≥ 1 unidad por disco; `T_delta` de la sincronización diaria cabe; SyncHot + Custom-Time hechos | Logs de Verify, CSV de `09-Hash-Sample`, CSV de Verify de 07 |
| GC Corte | Sáb 05-dic | Vista previa de purge revisada; Delta final con código < 8; prueba de aceptación de FM2 por VPN (abrir, guardar, buscar) OK; DFS/mapeos de unidades cambiados | Acta de aprobación |
| GA Archivo | Tras la carga de lo Frío | Todo lo Frío `Verified`; análisis antimalware limpio; `Verify` de 07 con `Match=True` en todas las carpetas Frías; manifiestos subidos → política de retención aplicada → disco temporal eliminado | CSV de Verify de 07, `gcloud storage buckets describe` |

Muestra de hash por disco (primero en el origen y después en la VM con la misma lista):

```powershell
# AGACE-FS01
.\09-Hash-Sample.ps1 -Root 'W:\Sistemas\<Unidad>' -OutCsv C:\AGACE-Migration\logs\hash_W_src.csv
Copy-Item C:\AGACE-Migration\logs\hash_W_src.csv '\\agace-gcp-fs01.agace.local\ColdStage$\_control\'
# VM (lectura de disco local, sin WAN)
powershell -File E:\AGACE\scripts\09-Hash-Sample.ps1 -Root 'E:\AGACE\Hot\W_Sistemas\<Unidad>' -SampleFrom S:\AGACE\Cold\_control\hash_W_src.csv -OutCsv S:\AGACE\Cold\_control\hash_W_dst.csv
# En cualquiera de los dos
Compare-Object (Import-Csv hash_W_src.csv) (Import-Csv hash_W_dst.csv) -Property RelPath, SHA256    # sin salida = APROBADO
```

### 5.7 Plantilla del plan por noche (ajustar con datos reales después de la Compuerta P)

| Noche | Alcance planeado | TB plan | TB real | Acumulado | Estado |
|---|---|---|---|---|---|
| N1 lun 23-nov | D: + carpetas aprobadas de C: (valida el proceso), después W: Caliente | | | | |
| N2–N4 | W: Caliente, F: Caliente, G: Caliente (en paralelo, un trabajo por disco) | | | | |
| N5 | Resto de lo Caliente; la sincronización diaria ya cubre la mayoría de las unidades Calientes | | | | |
| N6 | Verify de lo Caliente (corrida diurna de fin de semana) → Compuerta H; W: Frío | | | | |
| N7–N9 | W: Frío, F: Frío; siembra (2.6); G: Frío | | | | |
| N10 mié 02-dic | Resto de lo Frío, reintentos | | | | |
| Reserva jue–vie | Unidades Failed/Partial, Verify final | | | | |
| Sáb 05-dic | Corte (Compuerta C) | | | | |

---

## 6. Plan de reversión y contingencia

### 6.1 Principios

* El origen es de solo lectura para la migración: robocopy nunca borra ni mueve nada en AGACE-FS01. **Antes del corte, revertir = detener las tareas.** Los usuarios siguen trabajando en el origen como siempre.
* Cada unidad es idempotente. Una nueva ejecución copia solo lo que difiere, así que cualquier falla se recupera ejecutando la misma unidad otra vez.
* El origen se conserva intacto y en solo lectura **90 días después del corte**. Ningún disco se borra ni se reutiliza antes de eso, y nunca antes de la Compuerta A.
* Use un espacio de nombres DFS (`\\agace.local\Datos`) o mapeos de unidades por GPO, para que el corte y la reversión sean un cambio de destino y no un cambio en cada PC.

### 6.2 Escenario A: limitación de red, falla del ISP o de la VPN

| Síntoma | Detección | Acción |
|---|---|---|
| Rendimiento < 70 % del plan durante 30 min | Evento 1101, `bw_*.csv` | Revisar ambos túneles VPN (`gcloud compute vpn-tunnels describe …`), el CPU del firewall y el ISP. Ejecutar `ping -l 1372 -f 10.50.0.10` para descartar problemas de MTU/fragmentación |
| Caída de túnel (`ERROR 64/53` en muchas unidades) | Las unidades terminan `Failed` | No hay nada que revertir. Las unidades se repiten la noche siguiente y HA VPN conmuta al segundo túnel |
| El ISP limita la velocidad después de X TB (uso justo) | Descenso constante noche tras noche | Pedir al ISP un plan temporal sin límite; agregar ventanas diurnas de fin de semana |
| Proyección AMBER | `projection.csv` | `-Tier Hot` hasta la Compuerta H; lo Frío continúa después del corte (sin impacto en la operación) |
| Proyección RED | `projection.csv` | Decisión de la dirección el mismo día: mover la fecha de corte, ancho de banda temporal, o traslado físico de lo Frío (Google Transfer Appliance: verificar disponibilidad en México; el plazo de entrega es de semanas, así que es solo una alternativa para lo Frío) |
| La saturación afecta el trabajo diurno | Quejas de usuarios | Las tareas nunca arrancan fuera de su ventana. Aplicar el límite QoS de 4.4 |

### 6.3 Escenario B: falla un disco origen a mitad de la migración (lo más probable: F: o G:, USB)

1. **Deje de leer el disco de inmediato.** Cada lectura adicional daña más a un disco que está fallando. Desactive las tareas, termine robocopy y ponga en `Hold` las unidades de ese disco:

```powershell
Disable-ScheduledTask -TaskPath '\AGACE\' -TaskName '01-Baseline'; Disable-ScheduledTask -TaskPath '\AGACE\' -TaskName '02-DailySync'
Get-Process robocopy -ErrorAction SilentlyContinue | Stop-Process -Force
$jf = 'C:\AGACE-Migration\jobs\jobs.csv'; $j = Import-Csv $jf
$j | Where-Object { $_.Source -like 'G:\*' -and $_.Status -notin 'Done', 'Verified' } | ForEach-Object { $_.Status = 'Hold' }
$j | Export-Csv $jf -NoTypeInformation -Encoding UTF8
Enable-ScheduledTask -TaskPath '\AGACE\' -TaskName '01-Baseline'; Enable-ScheduledTask -TaskPath '\AGACE\' -TaskName '02-DailySync'   # los demás discos continúan
```

2. **No ejecute `chkdsk /f`** sobre un disco que está fallando, porque puede destruir datos. Primero haga una imagen o clon a nivel sector (por ejemplo `ddrescue` desde un arranque Linux hacia un disco nuevo de igual o mayor capacidad, o un servicio profesional de recuperación si hay ruidos mecánicos).
3. Determine qué ya está a salvo:
   * unidades `Done`/`Verified` (ya están en la VM);
   * unidades cubiertas por `duplicates.csv` (los mismos datos existen en W:);
   * lo que quede es la exposición real.
4. Monte el clon con la **misma letra de unidad** y regrese las unidades `Hold` a `Pending`. Robocopy omite todo lo que ya es idéntico y continúa.
5. Documente los archivos que no se pudieron recuperar: las líneas `ERROR 23/1117` de los logs dan las rutas exactas. El área de cumplimiento de AGACE debe revisar esa lista (impacto en la conservación de registros).

Si falla un disco interno (D:/W:), el procedimiento es el mismo. Primero restaure el respaldo más reciente a un volumen nuevo con la misma letra.

### 6.4 Escenario C: problema en el destino

| Problema | Acción |
|---|---|
| VM o disco Caliente dañado o perdido | Restaurar `agace-hot` desde el snapshot más reciente (`agace-daily-0600`). El siguiente Baseline/Delta lo vuelve a igualar con el origen (idempotente) |
| Se pierde el disco temporal antes de la Compuerta A | Recrearlo; regresar a `Pending` las unidades Frías afectadas; copiar de nuevo (el origen está intacto) |
| Objetos erróneos en el bucket de archivo **antes** de la política de retención | Borrar y volver a subir (por eso la política se aplica hasta la Compuerta A) |
| Borrado o sobrescritura accidental en el bucket Caliente | Restaurar la versión anterior (`gcloud storage ls -a` y luego `gcloud storage cp gs://…#<generación> …`) o usar soft delete (7 días por defecto) |

### 6.5 Escenario D: reversión del corte (sáb 05-dic … lun 07-dic 08:00)

Disparador: falla la prueba de aceptación de FM2, el rendimiento por VPN es inaceptable o más del 1 % de los archivos no está accesible.

1. Regrese los destinos DFS o los mapeos por GPO a AGACE-FS01. Vuelva a habilitar los recursos compartidos del origen en lectura/escritura.
2. Copie de vuelta lo que los usuarios crearon en la VM después del corte, solo archivos más nuevos y sin borrar nada:

```bat
robocopy "E:\AGACE\Hot\W_Sistemas" "\\AGACE-FS01\W$\Sistemas" /E /XO /COPY:DATSO /DCOPY:DAT /B /MT:32 /R:2 /W:5 /XJ /UNILOG:E:\AGACE\rollback_W.log
```

3. Repita para cada carpeta de unidad (`C_Datos`, `D_Informacion`, `F_Lacie`, `G_Seagate`). Vuelva a habilitar la tarea `02-DailySync` para el siguiente intento y documente la causa raíz.

### 6.6 Matriz de decisiones

| Evento | Quién decide | Tiempo máximo de decisión | Acción por defecto |
|---|---|---|---|
| Evento 1101 / AMBER | Ingeniero de migración | La misma mañana | Primero lo Caliente |
| Proyección RED | Dirección de AGACE + ingeniero | El mismo día | Mover el corte |
| Errores de E/S en disco (23/1117) | Ingeniero, luego TI de AGACE | Inmediato | Detener el disco, hacer imagen (6.3) |
| Falla de la Compuerta C | Dirección de AGACE | Antes del lun 08:00 | Reversión (6.5) |
| Bloqueo de retención | Dirección de AGACE + asesores de cumplimiento | Sin fecha límite | No bloquear sin aprobación por escrito |

---

## 7. Lista de verificación final

| # | Fase | Actividad | Responsable | Compuerta | Hecho |
|---|---|---|---|---|---|
| 1 | Preparación | Confirmación legal de la fecha de corte (2021-01-01), del cómputo de 5 años y del periodo de bloqueo (A7) | Cumplimiento AGACE | G1 | ☐ |
| 2 | Preparación | Confirmar dominio AD, SO origen, arquitectura de FM2/BD y ancho de banda del ISP (A1–A5) | TI AGACE | G0 | ☐ |
| 3 | Preparación | SMART/salud de F: y G:; energía USB; Windows Update en pausa | TI AGACE | G0 | ☐ |
| 4 | GCP | VPC, HA VPN (MSS 1360), firewall 445/IAP, VM, discos, programación de snapshots | Ingeniero | G0 | ☐ |
| 5 | GCP | VM: zona horaria = origen, LongPaths, unión al dominio, E:/S:, recursos compartidos, PowerShell 7, gcloud | Ingeniero | G0 | ☐ |
| 6 | GCP | Buckets creados (activa Standard + versionado; histórico Archive), PAP, UBLA | Ingeniero | G0 | ☐ |
| 7 | GCP | JSON de ciclo de vida aplicado y verificado (`describe`) | Ingeniero | G0 | ☐ |
| 8 | GCP | Permisos IAM; registros de auditoría de acceso a datos activados | Ingeniero | G0 | ☐ |
| 9 | Inventario | Lista de carpetas de C: aprobada (`C_candidates.csv`) | TI AGACE | G1 | ☐ |
| 10 | Inventario | Lista de BD/PST revisada; plan de respaldo nativo para BD en uso | TI AGACE | G1 | ☐ |
| 11 | Inventario | `01-Inventory` ejecutado; todos los `Review` resueltos; TB Caliente/Frío registrados | Ingeniero + AGACE | G1 | ☐ |
| 12 | Inventario | Duplicados G:↔W:: L1/L2/L3 hechos; Estrategia A/B decidida por escrito | Ingeniero + AGACE | G1 | ☐ |
| 13 | Inventario | `jobs.csv` generado; unidades duplicadas de G: en `Hold` | Ingeniero | G1 | ☐ |
| 14 | Piloto | Piloto grande/pequeño; R_eff, F_rate, dialecto SMB y RTT registrados; SE AUTORIZA / NO SE AUTORIZA | Ingeniero | GP | ☐ |
| 15 | Programación | `06-Register-Tasks` ejecutado; prueba "0 units run"; origen de eventos OK | Ingeniero | GP | ☐ |
| 16 | Programación | Tareas VM-SyncHot / VM-UploadCold registradas en la VM | Ingeniero | GP | ☐ |
| 17 | Ejecución | Revisiones matutinas N1–N10 registradas (proyección, Failed/Fatal, espacio libre) | Ingeniero | GN | ☐ |
| 18 | Ejecución | Script de siembra ejecutado en la VM; unidades de G: liberadas | Ingeniero | GN | ☐ |
| 19 | Verificación | Todo lo Caliente `Verified`; muestras de hash APROBADAS por disco; la sincronización diaria cabe en su ventana | Ingeniero | GH | ☐ |
| 20 | Verificación | SyncHot completo; prueba y marcado de Custom-Time realizados | Ingeniero | GH | ☐ |
| 21 | Corte | Vista previa de purge revisada; Delta final; prueba de aceptación de FM2; DFS/mapeos cambiados | Ingeniero + AGACE | GC | ☐ |
| 22 | Corte | Recursos del origen en solo lectura; tareas del origen desactivadas; VM-SyncHot movida a la 01:00 | TI AGACE | GC | ☐ |
| 23 | Archivo | Todo lo Frío `Verified`; análisis antimalware; UploadCold; Verify de 07 con `Match=True` | Ingeniero | GA | ☐ |
| 24 | Archivo | Manifiestos y logs en `_manifest/`; retención de 1826 días aplicada | Ingeniero | GA | ☐ |
| 25 | Archivo | Aprobación por escrito → `--lock-retention-period` (irreversible) | Dirección AGACE + cumplimiento | GA | ☐ |
| 26 | Cierre | Cuenta de servicio de la VM → objectViewer en el archivo; disco temporal eliminado; permisos de migración retirados | Ingeniero | GA | ☐ |
| 27 | Cierre | Origen conservado en solo lectura 90 días; aprobación de baja del equipo | Dirección AGACE | – | ☐ |

## 8. Aprobación de AGACE

Al firmar, AGACE aprueba el alcance, la clasificación Caliente/Frío, el calendario y el plan de reversión de este documento. Los puntos A1–A8 y las decisiones marcadas "confirmar con cumplimiento" quedan sujetos a la confirmación por escrito indicada en la lista de verificación.

| Función | Nombre | Firma | Fecha |
|---|---|---|---|
| Dirección general AGACE | | | |
| Responsable de TI AGACE | | | |
| Cumplimiento / asesor legal | | | |
| Ingeniero de migración | | | |

## Anexo A: archivos entregados

| Archivo | Se ejecuta en | Propósito |
|---|---|---|
| `scripts/00-Discover-C.ps1` | FS01 | Descubrimiento de carpetas de negocio en C: |
| `scripts/01-Inventory.ps1` | FS01 | Inventario y clasificación Caliente/Frío |
| `scripts/02-Find-Duplicates.ps1` | FS01 | Detección de duplicados G:↔W: (firma + robocopy /L) |
| `scripts/03-Build-Jobs.ps1` | FS01 | Genera `jobs.csv` a partir de la clasificación aprobada |
| `scripts/04-Run-Robocopy.ps1` | FS01 | Orquestador de baseline / sincronización diaria / verificación |
| `scripts/05-Monitor-Bandwidth.ps1` | FS01 | Medición de rendimiento y proyección de término |
| `scripts/06-Register-Tasks.ps1` | FS01 | Registro en el Programador de tareas |
| `scripts/07-VM-Gcs.ps1` | VM | Sincronización Caliente, carga de lo Frío, verificación en GCS |
| `scripts/08-VM-Stamp-CustomTime.ps1` | VM | Custom-Time = mes del documento para el ciclo de vida |
| `scripts/09-Hash-Sample.ps1` | FS01 + VM | Verificación por muestra SHA-256 |
| `scripts/10-Build-SeedScript.ps1` | FS01 → VM | Siembra de duplicados dentro de GCP |
| `gcp/lifecycle-operacion-activa.json` | Cloud Shell | Reglas de ciclo de vida del bucket Caliente |
