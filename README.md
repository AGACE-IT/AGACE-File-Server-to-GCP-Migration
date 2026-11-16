# AGACE-File-Server-to-GCP-Migration

Single source of truth for migrating the AGACE Matamoros file server (C:, D:\Informacion, F:\Lacie, G:\Seagate, W:\Sistemas; ≈ 11.2 TB) to Google Cloud using a Hot/Cold strategy.

| Path | Contents |
|---|---|
| `docs/AGACE_GCP_Migration_Runbook_EN.md` | Implementation runbook (English) |
| `docs/AGACE_Runbook_Migracion_GCP_ES-MX.md` | Runbook en español (MX), with the approval block |
| `Decisions.md` | Open assumptions A1–A8, with owner and deadline |
| `scripts/` | PowerShell scripts 00–10 (source server + GCP VM) |
| `gcp/lifecycle-operacion-activa.json` | Cloud Storage lifecycle rules for the Hot bucket |
| `Inventory_Results/` | Inventory outputs (`summary_folders.csv`, `duplicates.csv`) |
