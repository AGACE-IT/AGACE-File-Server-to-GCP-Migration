# Decisions / Decisiones: A1–A8

These are the assumptions from Section 0.3 of the runbook ([EN](docs/AGACE_GCP_Migration_Runbook_EN.md) · [ES-MX](docs/AGACE_Runbook_Migracion_GCP_ES-MX.md)). Each one needs a written answer from its owner before the gate shown. Record the answer, the date and who answered, then tick the box.

Owners:

* **IT**: AGACE IT
* **Legal**: AGACE compliance / legal counsel
* **Management**: AGACE management
* **Engineer**: Infinite Momentum engineers. They validate the answer technically, and AGACE IT is welcome to join.

## English

| ✔ | # | Question to answer | Owner | How to answer / evidence | Needed by | If the answer is "no" | Answer (who, date) |
|---|---|---|---|---|---|---|---|
| ☐ | A1 | Are the source server (AGACE-FS01) and the new GCP server in the **same Active Directory domain**? This lets robocopy copy NTFS permissions for active data. | IT (Engineer validates) | Domain name; `(Get-CimInstance Win32_ComputerSystem).Domain` on the source | Gate 1 (before job list) | Workgroup: copy without ACLs (`-HotCopy /COPY:DAT`) and re-apply permissions on the GCP server | |
| ☐ | A2 | Is the source OS **Windows Server 2012 R2 or later**, with **PowerShell 5.1**? | IT | `(Get-CimInstance Win32_OperatingSystem).Caption`; `$PSVersionTable.PSVersion` | **Tonight** (the inventory scripts require PowerShell 5.1) | 2008 R2: install WMF 5.1 first; expect lower throughput (SMB 2.1) | |
| ☐ | A3 | Are **F: (LaCie)** and **G: (Seagate)** external USB disks, and are they healthy? | IT (Engineer validates) | Runbook 1.1 health commands; vendor tool (SeaTools / LaCie Toolkit) if SMART is hidden | **Tonight** (pre-flight) | Any warning or read error: image the disk before copying (runbook 6.3) | |
| ☐ | A4 | Is FM2 data plain files? Do FM2 or any accounting system (e.g. CONTPAQi) keep **live SQL Server databases, PST/OST or Access files** on these drives? | IT + FM2 / application owner | `db_and_mail_files.log` from runbook 1.2; application owner confirms | Gate 1 | Live databases move by native backup/restore, not robocopy | |
| ☐ | A5 | What **sustained night-time bandwidth** do the uplink and VPN provide (contracted speed, any ISP fair-use cap)? The full 11.2 TB in 10 nights needs about 550 Mbps. | IT + Management (ISP contract) | ISP contract + tonight's pilot measurement (runbook 2.4 / 5.4) | Gate P (pilot) | Hot-first plan: Cold archive continues after cutover; or a temporary ISP upgrade | |
| ☐ | A6 | Must the data **stay in Mexico** (region `northamerica-south1`, Querétaro)? | Legal + Management | Written confirmation | Before GCP buckets are created (Gate 0) | No residency requirement: `us-south1` (Dallas) may give lower latency from Matamoros | |
| ☐ | A7 | Legal retention (Ley Aduanera, CFF, 2026 reform). (a) Is the **2021-01-01** Hot/Cold cutoff correct? (b) Does the 5-year clock run from the operation/pedimento date? The runbook uses the file modified date as a stand-in. (c) What **retention/lock period** applies? Locking is irreversible. | Legal | Written legal opinion | (a)(b) Gate 1; (c) before the retention lock (Gate A) | Change the cutoff in `01-Inventory.ps1` and the period in runbook 3.4 | |
| ☐ | A8 | Does the source server's **Windows time zone** match Matamoros (US-style DST)? The GCP server must use the same zone. | IT (Engineer validates) | `tzutil /g` on the source | **Tonight** (pre-flight) | Fix the time zone first, otherwise copy windows and tasks drift by one hour | |

## Español (MX)

| ✔ | # | Pregunta | Responsable | Cómo responder / evidencia | Se necesita para | Si la respuesta es "no" | Respuesta (quién, fecha) |
|---|---|---|---|---|---|---|---|
| ☐ | A1 | ¿El servidor origen (AGACE-FS01) y el nuevo servidor en GCP están en el **mismo dominio de Active Directory**? Esto permite que robocopy copie los permisos NTFS de los datos activos. | TI (valida Ingeniero) | Nombre del dominio; `(Get-CimInstance Win32_ComputerSystem).Domain` en el origen | Compuerta 1 (antes de la lista de trabajos) | Grupo de trabajo: copiar sin permisos (`-HotCopy /COPY:DAT`) y volver a aplicarlos en el servidor de GCP | |
| ☐ | A2 | ¿El sistema operativo origen es **Windows Server 2012 R2 o posterior**, con **PowerShell 5.1**? | TI | `(Get-CimInstance Win32_OperatingSystem).Caption`; `$PSVersionTable.PSVersion` | **Hoy en la noche** (los scripts de inventario requieren PowerShell 5.1) | 2008 R2: instalar WMF 5.1 primero; esperar menor rendimiento (SMB 2.1) | |
| ☐ | A3 | ¿**F: (LaCie)** y **G: (Seagate)** son discos externos USB, y están sanos? | TI (valida Ingeniero) | Comandos de salud del runbook 1.1; herramienta del fabricante (SeaTools / LaCie Toolkit) si SMART está oculto | **Hoy en la noche** (revisión previa) | Cualquier advertencia o error de lectura: hacer imagen del disco antes de copiar (runbook 6.3) | |
| ☐ | A4 | ¿Los datos de FM2 son archivos? ¿FM2 o algún sistema contable (p. ej. CONTPAQi) guarda **bases de datos SQL Server en uso, PST/OST o archivos de Access** en estas unidades? | TI + responsable de FM2 / aplicación | `db_and_mail_files.log` del runbook 1.2; confirmación del responsable de la aplicación | Compuerta 1 | Las bases de datos en uso se mueven con respaldo/restauración nativo, no con robocopy | |
| ☐ | A5 | ¿Qué **ancho de banda nocturno sostenido** dan el enlace y la VPN (velocidad contratada, límite de uso justo del ISP)? Los 11.2 TB completos en 10 noches requieren ~550 Mbps. | TI + Dirección (contrato con el ISP) | Contrato del ISP + medición del piloto de hoy (runbook 2.4 / 5.4) | Compuerta P (piloto) | Plan "primero lo Caliente": el archivo Frío continúa después del corte; o ampliación temporal con el ISP | |
| ☐ | A6 | ¿Los datos deben **permanecer en México** (región `northamerica-south1`, Querétaro)? | Legal + Dirección | Confirmación por escrito | Antes de crear los buckets en GCP (Compuerta 0) | Sin requisito de residencia: `us-south1` (Dallas) puede dar menor latencia desde Matamoros | |
| ☐ | A7 | Conservación legal (Ley Aduanera, CFF, reforma 2026). (a) ¿Es correcta la fecha de corte Caliente/Frío **2021-01-01**? (b) ¿Los 5 años se cuentan desde la fecha de la operación/pedimento? El runbook usa la fecha de modificación del archivo como aproximación. (c) ¿Qué **periodo de retención/bloqueo** aplica? El bloqueo es irreversible. | Legal | Opinión legal por escrito | (a)(b) Compuerta 1; (c) antes del bloqueo de retención (Compuerta A) | Cambiar la fecha de corte en `01-Inventory.ps1` y el periodo en el runbook 3.4 | |
| ☐ | A8 | ¿La **zona horaria de Windows** del servidor origen corresponde a Matamoros (horario de verano estilo EE. UU.)? El servidor de GCP debe usar la misma. | TI (valida Ingeniero) | `tzutil /g` en el origen | **Hoy en la noche** (revisión previa) | Corregir la zona horaria primero; si no, las ventanas de copia y las tareas se desfasan una hora | |
