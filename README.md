# ado2gh Extended Inventory Report

A PowerShell script that generates an Azure DevOps inventory report equivalent to `gh ado2gh inventory-report`, but with **full cross-project pipeline awareness** and opt-in richer repo statistics — the blind spots that the native `ado2gh` tool misses.

## The Problem with `ado2gh inventory-report`

The built-in `ado2gh inventory-report` command counts pipelines per repo, but only looks at pipelines within the **same project** as the repo. In Azure DevOps it is common for a pipeline defined in **Project A** to build source code from a repository in **Project B**. These cross-project relationships are silently ignored, leading to:

- Repos that appear to have zero pipelines when they actually have several
- Pipeline counts that are lower than reality at the project and org level
- Missing pipeline entries that could cause surprises during a GitHub migration

## What This Script Does Differently

`Invoke-ADOInventoryReport.ps1` iterates every pipeline definition across **all projects** and resolves which repo each pipeline actually targets — regardless of which project owns the pipeline. It also exposes per-repo statistics (PR count, commits in the past year, top contributor) behind opt-in switches so you pay only for the API calls you need.

## Terminal Output

The script produces `ado2gh`-style timestamped log output. Regular messages are white; CSV-generated confirmations are green.

```
[2026-04-22 03:10:06] [INFO] ADO ORG: rodesaro4
[2026-04-22 03:10:06] [INFO] Creating inventory report...
[2026-04-22 03:10:06] [INFO] Commit metric enabled: commits-past-year will be queried.
[2026-04-22 03:10:06] [INFO] PR metric enabled: pr-count will be queried.
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
[2026-04-22 03:10:08] [INFO] Generating team-projects.csv...
[2026-04-22 03:10:08] [INFO] team-projects.csv generated  ← green
[2026-04-22 03:10:08] [INFO] Generating repos.csv...
[2026-04-22 03:10:16] [INFO] repos.csv generated          ← green
[2026-04-22 03:10:16] [INFO] Generating pipelines.csv...
[2026-04-22 03:10:16] [INFO] pipelines.csv generated      ← green
```

When no optional metric switches are provided, the script logs:
```
[2026-04-22 03:10:06] [INFO] No optional repo metrics requested (-Commit/-Pr/-Contributor not specified). Expensive repo stats will be skipped.
```

## Output Files

### `orgs.csv`
One row per organization.

| Column | Description |
|--------|-------------|
| `name` | Organization name |
| `url` | Organization URL |
| `owner` | Organization name |
| `teamproject-count` | Total number of team projects |
| `repo-count` | Total repos across all projects |
| `pipeline-count` | Total pipelines across all projects |
| `is-pat-org-admin` | Always `unknown` (requires elevated PAT scope to determine) |
| `pr-count` | Total PRs across all repos — populated only when `-Pr` is specified; blank otherwise |

### `team-projects.csv`
One row per team project.

| Column | Description |
|--------|-------------|
| `org` | Organization name |
| `teamproject` | Project name |
| `url` | Project URL |
| `repo-count` | Repos in this project |
| `pipeline-count` | Pipelines defined in this project |
| `pr-count` | Total PRs across repos in this project — populated only when `-Pr` is specified; blank otherwise |

### `repos.csv`
One row per repository. Expensive columns are blank unless the corresponding switch is passed.

| Column | Always populated | Switch required | Description |
|--------|-----------------|-----------------|-------------|
| `org` | Yes | | Organization name |
| `teamproject` | Yes | | Project the repo belongs to |
| `repo` | Yes | | Repository name |
| `url` | Yes | | Clone URL |
| `last-push-date` | Yes | | Timestamp of the most recent push |
| `pipeline-count` | Yes | | Pipelines that build from this repo, org-wide (including cross-project) |
| `compressed-repo-size-in-bytes` | Yes | | Repo size in bytes (ADO reports KB; converted here) |
| `pr-count` | | `-Pr` | Total pull requests (all statuses) |
| `commits-past-year` | | `-Commit` | Commits in the last 365 days |
| `most-active-contributor` | | `-Contributor` | Author with the most commits in the past year |

### `pipelines.csv`
One row per pipeline, matching the `ado2gh` column order with one extension column.

| Column | Description |
|--------|-------------|
| `org` | Organization name |
| `teamproject` | Project the pipeline is defined in |
| `repo` | Name of the repository the pipeline builds from |
| `pipeline` | Pipeline name |
| `url` | Link to the pipeline definition in Azure DevOps |
| `cross-project-repo` | **Extension column.** Blank when the repo lives in the same project as the pipeline. Set to `ProjectName/RepoName` when the repo is in a different project — these are the relationships `ado2gh` would have missed entirely. |

## Requirements

- PowerShell 5.1+ (tested on PowerShell 7)
- An Azure DevOps Personal Access Token (PAT) with **Read** access on:
  - **Code** (Git repositories, pushes, pull requests, commits)
  - **Build** (pipeline definitions)
  - **Project and Team**

## Usage

```powershell
# Fast run — pipeline attribution only, no expensive repo metrics
.\Invoke-ADOInventoryReport.ps1 -AdoOrg "your-org-name" -AdoPat "your-pat"

# Full run — all optional metrics
.\Invoke-ADOInventoryReport.ps1 -AdoOrg "your-org-name" -AdoPat "your-pat" -Commit -Pr -Contributor

# Selective — just PR counts and contributor info
.\Invoke-ADOInventoryReport.ps1 -AdoOrg "your-org-name" -Pr -Contributor

# Custom output directory using environment variable for PAT
$env:ADO_PAT = "your-pat"
.\Invoke-ADOInventoryReport.ps1 -AdoOrg "your-org-name" -OutputDir "C:\reports" -Commit -Pr -Contributor
```

## Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-AdoOrg` | Yes | Azure DevOps organization name |
| `-AdoPat` | No | PAT token. Falls back to `$env:ADO_PAT` if omitted |
| `-OutputDir` | No | Directory to write CSV files. Created if it does not exist. Defaults to current directory |
| `-Commit` | No | Query commit history and populate `commits-past-year` in repos.csv |
| `-Pr` | No | Query pull requests and populate `pr-count` in repos.csv, team-projects.csv, and orgs.csv |
| `-Contributor` | No | Query commit history and populate `most-active-contributor` in repos.csv |

> **Note:** `-Commit` and `-Contributor` both query commit history. When both are specified, the history is fetched once and used for both fields.

## How Cross-Project Resolution Works

Pipeline-to-repo attribution is handled by the `Resolve-BuildRepository` function, which uses a layered approach to extract the repo name and owning project from both the abbreviated pipeline list response and the full build definition:

1. **Full definition fetch** — the full build definition is retrieved for every pipeline (`GET /build/definitions/{id}`). Both the abbreviated `repository` object from the list and the `repository` object from the full definition are examined.

2. **GUID lookup** — if a `repository.id` GUID is found in either source, it is matched against a pre-built map of all fetched repos (normalized to lowercase to handle ADO's inconsistent GUID casing). This gives an exact, unambiguous match.

3. **Nested property scan** — for non-standard pipeline types, the script also checks `repository.properties.fullName`, `repository.properties.repositoryName`, and `repository.properties.projectName` to find a repo and project name.

4. **Name match** — as a fallback, the resolved repo name is matched first against repos in the pipeline's own project, then across all fetched repos org-wide.

```
Pipeline (Project A)
  └─ repository.id            = <guid>   ← matched against pre-built lookup map
  └─ repository.name          = "my-repo"
  └─ repository.project.name  = "Project B"   ← used for cross-project attribution
                                                ← ado2gh ignores this entirely
```

### Commit History API

Commits are fetched via the `POST /git/repositories/{id}/commitsbatch` endpoint rather than the `GET /commits` endpoint. The POST API is more reliable for date-filtered paginated queries and avoids URL-encoding edge cases with ISO 8601 timestamps.

## Comparison with `ado2gh inventory-report`

| Feature | `ado2gh` | This script |
|---------|----------|-------------|
| Repos per project | Yes | Yes |
| Pipelines per project | Yes | Yes |
| Pipeline → repo attribution | Same project only | Org-wide (cross-project) |
| `cross-project-repo` column | No | Yes |
| PR count | Yes | Yes, with `-Pr` (paginates all statuses) |
| Commits past year | Partial / 0 | Yes, with `-Commit` |
| Most active contributor | No | Yes, with `-Contributor` |
| Repo size | Yes | Yes |
| Project names with spaces / special chars | Yes | Yes (URL-encoded) |
| ado2gh-style terminal output | Yes | Yes (matching timestamp + color format) |
| PAT env var support | Yes | Yes (`ADO_PAT`) |
