# ado2gh Extended Inventory Report

A PowerShell script that generates an Azure DevOps inventory report equivalent to `gh ado2gh inventory-report`, but with **full cross-project pipeline awareness** — the blind spot that the native `ado2gh` tool misses.

## The Problem with `ado2gh inventory-report`

The built-in `ado2gh inventory-report` command counts pipelines per repo, but only looks at pipelines within the **same project** as the repo. In Azure DevOps it is common for a pipeline defined in **Project A** to build source code from a repository in **Project B**. These cross-project relationships are silently ignored, leading to:

- Repos that appear to have zero pipelines when they actually have several
- Pipeline counts that are lower than reality at the project and org level
- Missing pipeline entries that could cause surprises during a GitHub migration

## What This Script Does Differently

`Invoke-ADOInventoryReport.ps1` iterates every pipeline definition across **all projects**, fetches the full build definition to read the `repository.project.name` field, and attributes each pipeline to the repo it **actually** targets — regardless of which project owns the pipeline.

The result is an accurate, org-wide picture of the repo ↔ pipeline relationship.

## Output Files

| File | Description |
|------|-------------|
| `orgs.csv` | Organization-level summary (total projects, repos, pipelines, PRs) |
| `team-projects.csv` | Per-project summary with accurate repo, pipeline, and PR counts |
| `repos.csv` | Per-repo details including accurate `pipeline-count`, last push date, size, and PR count |
| `pipelines.csv` | All pipelines with an extra `is-cross-project` column (`true`/`false`) that flags pipelines whose repo lives in a different project |

The `pipelines.csv` `is-cross-project` column is the key addition — it lets you immediately spot and audit the relationships that `ado2gh` would have missed.

## Requirements

- PowerShell 7+ (uses null-conditional operator `?.`)
- An Azure DevOps Personal Access Token (PAT) with **Read** access on:
  - **Code** (Git repositories)
  - **Build** (pipeline definitions)
  - **Project and Team**

## Usage

```powershell
# Pass the PAT directly
.\Invoke-ADOInventoryReport.ps1 -AdoOrg "your-org-name" -AdoPat "your-pat"

# Or use an environment variable
$env:ADO_PAT = "your-pat"
.\Invoke-ADOInventoryReport.ps1 -AdoOrg "your-org-name"

# Write output to a specific directory
.\Invoke-ADOInventoryReport.ps1 -AdoOrg "your-org-name" -OutputDir "C:\reports"
```

## Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-AdoOrg` | Yes | Azure DevOps organization name |
| `-AdoPat` | No | PAT token. Falls back to `$env:ADO_PAT` if omitted |
| `-OutputDir` | No | Directory to write CSV files. Defaults to current directory |

## How Cross-Project Resolution Works

For each pipeline definition the script calls the full build definition endpoint (`GET /build/definitions/{id}`). The response includes a `repository` object that, for Azure Repos Git pipelines (`type: TfsGit`), contains a `project.name` field pointing to the project that **owns the repo** — not necessarily the project that owns the pipeline. The script uses this field to construct the `ProjectName/RepoName` key and correctly attribute the pipeline count on the repo row.

```
Pipeline (Project A)
  └─ repository.type        = "TfsGit"
  └─ repository.name        = "my-repo"
  └─ repository.project.name = "Project B"   ← ado2gh ignores this
                                               ← this script uses it
```

## Comparison with `ado2gh inventory-report`

| Feature | `ado2gh` | This script |
|---------|----------|-------------|
| Repos per project | Yes | Yes |
| Pipelines per project | Yes | Yes |
| Pipeline → repo attribution | Same project only | Org-wide (cross-project) |
| `is-cross-project` flag | No | Yes |
| PAT env var support | Yes | Yes (`ADO_PAT`) |
