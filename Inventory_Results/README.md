# Inventory_Results

Drop the inventory outputs here (runbook sections 1.3–1.4):

| File | Produced by | Location on AGACE-FS01 |
|---|---|---|
| `summary_folders.csv` | `scripts/01-Inventory.ps1` | `C:\AGACE-Migration\inventory\summary_folders.csv` |
| `duplicates.csv` | `scripts/02-Find-Duplicates.ps1` | `C:\AGACE-Migration\inventory\duplicates.csv` |

Use a dated subfolder for each run, e.g. `Inventory_Results/2026-11-16/`.

Do **not** add the per-file lists (`files_*.tsv`) or the robocopy logs. They can be hundreds of MB, over GitHub's 100 MB file limit, and they list every file name.

> **Confidentiality:** these CSVs contain client folder names and paths from AGACE's customs files. This repository is currently **public**, so `.gitignore` blocks `*.csv`, `*.tsv` and `*.log` in this folder. Once the repository is private, delete `Inventory_Results/.gitignore` to allow commits.

---

Coloque aquí los resultados del inventario (secciones 1.3–1.4 del runbook): `summary_folders.csv` y `duplicates.csv`, en una subcarpeta por fecha. No agregue los listados por archivo (`files_*.tsv`) ni los logs de robocopy.

> **Confidencialidad:** estos CSV contienen nombres de carpetas de clientes de AGACE. Mientras el repositorio sea **público**, `.gitignore` bloquea `*.csv`, `*.tsv` y `*.log` en esta carpeta. Cuando el repositorio sea privado, borre `Inventory_Results/.gitignore`.
