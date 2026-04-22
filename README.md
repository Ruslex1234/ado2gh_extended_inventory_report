# ado2gh Extended Inventory Report

A PowerShell script that generates an Azure DevOps inventory report equivalent to `gh ado2gh inventory-report`, but with **full cross-project pipeline awareness** and richer per-repo statistics — the blind spots that the native `ado2gh` tool misses.

## The Problem with `ado2gh inventory-report`

The built-in `ado2gh inventory-report` command counts pipelines per repo, but only looks at pipelines within the **same project** as the repo. In Azure DevOps it is common for a pipeline defined in **Project A** to build source code from a repository in **Project B**. These cross-project relationships are silently ignored, leading to:

- Repos that appear to have zero pipelines when they actually have several
- Pipeline counts that are lower than reality at the project and org level
- Missing pipeline entries that could cause surprises during a GitHub migration

## What This Script Does Differently

`Invoke-ADOInventoryReport.ps1` iterates every pipeline definition across **all projects** and resolves which repo each pipeline actually targets — regardless of which project owns the pipeline. It also fills in per-repo statistics (PR count, commits in the past year, top contributor) that `ado2gh` leaves blank or under-reports.

## Terminal Output

The script produces `ado2gh`-style timestamped log output. Regular messages are white; CSV-generated confirmations are green.

```
[2026-04-22 03:10:06] [INFO] ADO ORG: rodesaro4
[2026-04-22 03:10:06] [INFO] Creating inventory report...
[2026-04-22 03:10:06] [INFO] Finding Orgs...
[2026-04-22 03:10:06] [INFO] Found 1 Orgs
[2026-04-22 03:10:06] [INFO] Finding Team Projects...
[2026-04-22 03:10:06] [INFO] Found 3 Team Projects
[2026-04-22 03:10:06] [INFO] Finding Repos...
[2026-04-22 03:10:07] [INFO] Found 7 Repos
[2026-04-22 03:10:07] [INFO] Finding Pipelines...
[2026-04-22 03:10:08] [INFO] Found 6 Pipelines
[2026-04-22 03:10:08] [INFO] Generating orgs.csv...
[2026-04-22 03:10:08] [INFO] orgs.csv generated          ← green
[2026-04-22 03:10:08] [INFO] Generating teamprojects.csv...
[2026-04-22 03:10:08] [INFO] team-projects.csv generated  ← green
[2026-04-22 03:10:08] [INFO] Generating repos.csv...
[2026-04-22 03:10:16] [INFO] repos.csv generated          ← green
[2026-04-22 03:10:16] [INFO] Generating pipelines.csv...
[2026-04-22 03:10:16] [INFO] pipelines.csv generated      ← green
```

## Output Files

### `orgs.csv`
One row per organization.

| Column | Description |
|--------|-------------|
| `name` | Organization name |
| `url` | Organization URL |
| `owner` | Organization name (same as `name`) |
| `teamproject-count` | Total number of team projects |
| `repo-count` | Total repos across all projects |
| `pipeline-count` | Total pipelines across all projects |
| `is-pat-org-admin` | Always `unknown` (requires elevated PAT scope to determine) |
| `pr-count` | Total pull requests (all statuses) across all repos |

### `team-projects.csv`
One row per team project.

| Column | Description |
|--------|-------------|
| `org` | Organization name |
| `teamproject` | Project name |
| `url` | Project URL |
| `repo-count` | Repos in this project |
| `pipeline-count` | Pipelines defined in this project |
| `pr-count` | Total PRs across all repos in this project |

### `repos.csv`
One row per repository with accurate stats.

| Column | Description |
|--------|-------------|
| `org` | Organization name |
| `teamproject` | Project the repo belongs to |
| `repo` | Repository name |
| `url` | Clone URL |
| `last-push-date` | Timestamp of the most recent push |
| `pipeline-count` | Number of pipelines that build from this repo (org-wide, including cross-project pipelines) |
| `compressed-repo-size-in-bytes` | Repo size in bytes (ADO reports in KB; converted here) |
| `most-active-contributor` | Author with the most commits in the past year |
| `pr-count` | Total pull requests (all statuses) against this repo |
| `commits-past-year` | Number of commits in the last 365 days |

### `pipelines.csv`
One row per pipeline, matching the `ado2gh` column order with one extension column.

| Column | Description |
|--------|-------------|
| `org` | Organization name |
| `teamproject` | Project the pipeline is defined in |
| `repo` | Name of the repository the pipeline builds from |
| `pipeline` | Pipeline name |
| `url` | Link to the pipeline definition in Azure DevOps |
| `cross-project-repo` | **Extension column.** Blank when the repo lives in the same project as the pipeline. Set to `ProjectName/RepoName` when the repo is in a different project — these are the entries `ado2gh` would have missed entirely. |

## Requirements

- PowerShell 7.1+ (uses the null-conditional operator `?.`)
- An Azure DevOps Personal Access Token (PAT) with **Read** access on:
  - **Code** (Git repositories, pushes, pull requests, commits)
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

Resolving which repo a pipeline targets uses a four-layer strategy, falling through only when the previous layer fails:

**Layer 1 — GUID lookup (no extra API call)**
The build definitions list response includes `repository.id` (a GUID). Since all repos are fetched in step 2, a pre-built map of `repoId → {project, name}` resolves the attribution instantly. GUIDs are normalized to lowercase on both sides to handle inconsistent casing between ADO API endpoints.

**Layer 2 — Name match within the same project**
Handles cases where `repository.id` is absent from the abbreviated list response. If a repo with the same name exists in the pipeline's own project, it is attributed there without an API call.

**Layer 3 — Full build definition fetch**
For genuine cross-project scenarios where layers 1 and 2 don't resolve, the full build definition (`GET /build/definitions/{id}`) is fetched. The `repository.project.name` field in the full response identifies the actual owning project. If this API call fails (some pipeline types return 400), the pipeline is still recorded rather than silently dropped.

**Layer 4 — Cross-project name scan**
Last resort. Searches all fetched repos across all projects for a name match.

```
Pipeline (Project A)
  └─ repository.id            = <guid>   ← matched against pre-built map (Layer 1)
  └─ repository.name          = "my-repo"
  └─ repository.project.name  = "Project B"   ← used in Layer 3 if Layer 1 misses
                                                ← ado2gh ignores this entirely
```

## Comparison with `ado2gh inventory-report`

| Feature | `ado2gh` | This script |
|---------|----------|-------------|
| Repos per project | Yes | Yes |
| Pipelines per project | Yes | Yes |
| Pipeline → repo attribution | Same project only | Org-wide (cross-project) |
| Cross-project repo column | No | Yes (`cross-project-repo`) |
| PR count | Yes | Yes (accurate: paginates all statuses) |
| Commits past year | Partial / 0 | Yes (paginates full year) |
| Most active contributor | No | Yes (top author by commit count, past year) |
| Repo size | Yes | Yes |
| ado2gh-style terminal output | Yes | Yes (matching timestamp + color format) |
| PAT env var support | Yes | Yes (`ADO_PAT`) |
