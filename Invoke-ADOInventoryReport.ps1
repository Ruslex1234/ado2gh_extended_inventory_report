<#
.SYNOPSIS
    Generates an ADO inventory report equivalent to `gh ado2gh inventory-report`
    but with full cross-project pipeline awareness.

.DESCRIPTION
    Produces four CSV files:
        orgs.csv            - Organization-level summary
        team-projects.csv   - Per-project summary
        repos.csv           - Per-repo details with accurate pipeline counts
        pipelines.csv       - All pipelines, including those that reference
                              repos in OTHER projects (the ado2gh blind spot)

.PARAMETER AdoOrg
    Your Azure DevOps organization name (e.g. "rodesaro4")

.PARAMETER AdoPat
    Personal Access Token with Read access on Code, Build, and Project.
    If omitted, falls back to the ADO_PAT environment variable.

.PARAMETER OutputDir
    Directory to write the four CSV files. Defaults to current directory.

.EXAMPLE
    .\Invoke-ADOInventoryReport.ps1 -AdoOrg "rodesaro4" -AdoPat "xxxx"

.EXAMPLE
    $env:ADO_PAT = "xxxx"
    .\Invoke-ADOInventoryReport.ps1 -AdoOrg "rodesaro4" -OutputDir "C:\reports"
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$AdoOrg,

    [Parameter(Mandatory = $false)]
    [string]$AdoPat = $env:ADO_PAT,

    [Parameter(Mandatory = $false)]
    [string]$OutputDir = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Get-AuthHeader {
    $token = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$AdoPat"))
    return @{ Authorization = "Basic $token"; "Content-Type" = "application/json" }
}

function Invoke-AdoApi {
    param (
        [string]$Url,
        [hashtable]$Headers = (Get-AuthHeader)
    )
    try {
        $response = Invoke-RestMethod -Uri $Url -Headers $Headers -Method Get
        return $response
    }
    catch {
        Write-Warning "API call failed: $Url`n$($_.Exception.Message)"
        return $null
    }
}

function Get-AllPages {
    <#
        ADO list APIs are capped at 100 items per call.
        This fetches all pages using continuationToken or $top/$skip.
    #>
    param (
        [string]$BaseUrl,
        [hashtable]$Headers = (Get-AuthHeader),
        [string]$ValueProperty = "value"
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $separator = if ($BaseUrl -match "\?") { "&" } else { "?" }
    $top = 200
    $skip = 0

    do {
        $url = "${BaseUrl}${separator}`$top=${top}&`$skip=${skip}"
        $response = Invoke-AdoApi -Url $url -Headers $Headers
        if ($null -eq $response) { break }

        $page = if ($response.PSObject.Properties[$ValueProperty]) { $response.$ValueProperty } else { $null }
        if ($null -eq $page -or $page.Count -eq 0) { break }

        $results.AddRange([object[]]$page)
        $skip += $page.Count

        if ($page.Count -lt $top) { break }
    } while ($true)

    return $results
}

function ConvertTo-CsvSafe {
    param([string]$Value)
    if ($null -eq $Value) { return "" }
    $v = $Value.ToString().Trim()
    if ($v -match '[,"\r\n]') {
        $v = '"' + $v.Replace('"', '""') + '"'
    }
    return $v
}

function Write-Csv {
    param (
        [string]$Path,
        [string[]]$Headers,
        [object[]]$Rows
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add($Headers -join ",")
    foreach ($row in $Rows) {
        $cells = foreach ($h in $Headers) {
            ConvertTo-CsvSafe -Value $row[$h]
        }
        $lines.Add($cells -join ",")
    }
    $lines | Set-Content -Path $Path -Encoding UTF8
    Write-Host "  Written: $Path ($($Rows.Count) rows)"
}

# ---------------------------------------------------------------------------
# Validate PAT
# ---------------------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($AdoPat)) {
    throw "No PAT provided. Use -AdoPat or set the ADO_PAT environment variable."
}

$OutputDir = (Resolve-Path $OutputDir -ErrorAction SilentlyContinue)?.Path
if (-not $OutputDir) {
    $OutputDir = (New-Item -ItemType Directory -Path $OutputDir -Force).FullName
}

$baseUrl  = "https://dev.azure.com/$AdoOrg"
$headers  = Get-AuthHeader

Write-Host "`nADO Inventory Report - Org: $AdoOrg"
Write-Host "Output directory: $OutputDir`n"

# ---------------------------------------------------------------------------
# 1. Fetch all team projects
# ---------------------------------------------------------------------------

Write-Host "[1/5] Fetching team projects..."
$projectsResponse = Invoke-AdoApi -Url "$baseUrl/_apis/projects?api-version=7.1&`$top=500" -Headers $headers
$projects = $projectsResponse.value
Write-Host "      Found $($projects.Count) project(s)"

# ---------------------------------------------------------------------------
# 2. Fetch repos per project + stats
# ---------------------------------------------------------------------------

Write-Host "[2/5] Fetching repositories..."

$allRepos = [System.Collections.Generic.List[hashtable]]::new()

# repoKey -> list of pipeline names (populated in step 3)
$repoPipelineMap  = @{}   # "ProjectName/RepoName" -> [List of pipeline display names]
$repoLastPushMap  = @{}   # "ProjectName/RepoName" -> last push date string
$repoPrCountMap   = @{}   # "ProjectName/RepoName" -> pr count
$repoSizeMap      = @{}   # "ProjectName/RepoName" -> size in bytes

foreach ($project in $projects) {
    $projName = $project.name
    $repos = Get-AllPages -BaseUrl "$baseUrl/$projName/_apis/git/repositories?api-version=7.1" -Headers $headers

    foreach ($repo in $repos) {
        $repoName = $repo.name
        $repoKey  = "$projName/$repoName"
        $repoUrl  = $repo.remoteUrl

        # Size (bytes) — ADO returns KB in repo.size
        $sizeBytes = 0
        if ($repo.PSObject.Properties['size'] -and $repo.size) { $sizeBytes = $repo.size * 1KB }

        # Last push date
        $lastPush = ""
        $pushesList = Invoke-AdoApi -Url "$baseUrl/$projName/_apis/git/repositories/$($repo.id)/pushes?api-version=7.1&`$top=1" -Headers $headers
        if ($pushesList -and $pushesList.value -and $pushesList.value.Count -gt 0) {
            $lastPush = $pushesList.value[0].date
        }

        # PR count (completed + active)
        $prCount = 0
        $prResp = Invoke-AdoApi -Url "$baseUrl/$projName/_apis/git/repositories/$($repo.id)/pullrequests?api-version=7.1&searchCriteria.status=all&`$top=1" -Headers $headers
        if ($prResp -and $prResp.count) { $prCount = $prResp.count }

        $topContributor  = ""
        $commitsPastYear = 0

        $repoPipelineMap[$repoKey]  = [System.Collections.Generic.List[string]]::new()
        $repoLastPushMap[$repoKey]  = $lastPush
        $repoPrCountMap[$repoKey]   = $prCount
        $repoSizeMap[$repoKey]      = $sizeBytes

        $allRepos.Add(@{
            _projName   = $projName
            _repoKey    = $repoKey
            _repoId     = $repo.id
            org         = $AdoOrg
            teamproject = $projName
            repo        = $repoName
            url         = $repoUrl
            "last-push-date"                  = $lastPush
            "pipeline-count"                  = 0    # filled in step 3
            "compressed-repo-size-in-bytes"   = $sizeBytes
            "most-active-contributor"         = $topContributor
            "pr-count"                        = $prCount
            "commits-past-year"               = $commitsPastYear
        })
    }
}

Write-Host "      Found $($allRepos.Count) repo(s) across all projects"

# Build repo-ID -> project/name maps so step 3 can resolve cross-project refs
# from the abbreviated pipeline list response — no extra per-pipeline API calls needed.
$repoIdToProject = @{}
$repoIdToName    = @{}
foreach ($r in $allRepos) {
    $rid = $r["_repoId"]
    if ($rid) {
        $repoIdToProject[$rid] = $r["_projName"]
        $repoIdToName[$rid]    = $r["repo"]
    }
}

# ---------------------------------------------------------------------------
# 3. Fetch ALL pipelines from ALL projects
#    KEY DIFFERENCE vs ado2gh: we resolve the ACTUAL repo the pipeline points
#    to (which may live in a DIFFERENT project) and attribute it correctly.
# ---------------------------------------------------------------------------

Write-Host "[3/5] Fetching pipelines (with cross-project repo resolution)..."

$allPipelines = [System.Collections.Generic.List[hashtable]]::new()

foreach ($project in $projects) {
    $projName = $project.name

    # Fetch pipeline definitions (build definitions)
    $defs = Get-AllPages -BaseUrl "$baseUrl/$projName/_apis/build/definitions?api-version=7.1&queryOrder=definitionNameAscending" -Headers $headers

    foreach ($def in $defs) {
        $pipelineName = $def.name
        $pipelineId   = $def.id
        $pipelineUrl  = "$baseUrl/$projName/_build/definition?definitionId=$pipelineId"

        $repoProject = $projName
        $repoName    = ""
        $repoType    = ""

        $repoInfo = if ($def.PSObject.Properties['repository']) { $def.repository } else { $null }
        if ($repoInfo) {
            $repoType = if ($repoInfo.PSObject.Properties['type']) { [string]$repoInfo.type } else { "" }
            $repoName = if ($repoInfo.PSObject.Properties['name']) { [string]$repoInfo.name } else { "" }
            $repoId   = if ($repoInfo.PSObject.Properties['id'])   { [string]$repoInfo.id }   else { "" }

            if ($repoType -eq "TfsGit") {
                if ($repoId -and $repoIdToProject.ContainsKey($repoId)) {
                    # Fast path: the abbreviated list response already has the repo ID;
                    # resolve project/name from our map without an extra API call.
                    $repoProject = $repoIdToProject[$repoId]
                    $repoName    = $repoIdToName[$repoId]
                } else {
                    # Slow path: repo not in our map (deleted, inaccessible project, etc.).
                    # Fetch full definition and guard every property access against strict mode.
                    $fullDef = Invoke-AdoApi -Url "$baseUrl/$projName/_apis/build/definitions/${pipelineId}?api-version=7.1" -Headers $headers
                    if ($fullDef) {
                        $fullRepo = if ($fullDef.PSObject.Properties['repository']) { $fullDef.repository } else { $null }
                        $projProp = if ($fullRepo -and $fullRepo.PSObject.Properties['project']) { $fullRepo.project } else { $null }
                        if ($projProp -and $projProp.PSObject.Properties['name']) {
                            $repoProject = [string]$projProp.name
                        }
                    }
                    # If the full fetch also fails, the pipeline still gets recorded
                    # with repoProject = $projName (same-project assumption).
                }
            }
            # Non-TfsGit sources (GitHub, external Git, etc.): repoProject stays as
            # $projName so is-cross-project is never misleadingly set for external repos.
        }

        $repoKey = "$repoProject/$repoName"

        if ($repoPipelineMap.ContainsKey($repoKey)) {
            $repoPipelineMap[$repoKey].Add($pipelineName)
        }

        # Cross-project is only meaningful for Azure Repos (TfsGit)
        $isCrossProject = ($repoType -eq "TfsGit") -and ($repoProject -ne $projName)

        $allPipelines.Add(@{
            org                = $AdoOrg
            "pipeline-project" = $projName
            "pipeline-name"    = $pipelineName
            "pipeline-id"      = $pipelineId
            "pipeline-url"     = $pipelineUrl
            "repo-project"     = $repoProject
            "repo-name"        = $repoName
            "repo-type"        = $repoType
            "is-cross-project" = $isCrossProject.ToString().ToLower()
        })
    }
}

Write-Host "      Found $($allPipelines.Count) pipeline(s) across all projects"

# ---------------------------------------------------------------------------
# 4. Back-fill pipeline-count into repos rows
# ---------------------------------------------------------------------------

Write-Host "[4/5] Calculating per-repo pipeline counts..."

foreach ($repo in $allRepos) {
    $key = $repo["_repoKey"]
    if ($repoPipelineMap.ContainsKey($key)) {
        $repo["pipeline-count"] = $repoPipelineMap[$key].Count
    }
}

# ---------------------------------------------------------------------------
# 5. Build summary rows and write CSVs
# ---------------------------------------------------------------------------

Write-Host "[5/5] Writing CSV files...`n"

# -- orgs.csv --
$totalRepos     = $allRepos.Count
$totalPipelines = $allPipelines.Count
$totalProjects  = $projects.Count
$totalPRs       = ($allRepos | ForEach-Object { [int]$_["pr-count"] } | Measure-Object -Sum).Sum

$orgRow = @{
    "name"               = $AdoOrg
    "url"                = "https://dev.azure.com/$AdoOrg"
    "owner"              = $AdoOrg
    "teamproject-count"  = $totalProjects
    "repo-count"         = $totalRepos
    "pipeline-count"     = $totalPipelines
    "is-pat-org-admin"   = "unknown"
    "pr-count"           = $totalPRs
}

Write-Csv `
    -Path (Join-Path $OutputDir "orgs.csv") `
    -Headers @("name","url","owner","teamproject-count","repo-count","pipeline-count","is-pat-org-admin","pr-count") `
    -Rows @($orgRow)

# -- team-projects.csv --
$teamProjectRows = foreach ($project in $projects) {
    $projName    = $project.name
    $projRepos   = $allRepos | Where-Object { $_["_projName"] -eq $projName }
    $projPipes   = $allPipelines | Where-Object { $_["pipeline-project"] -eq $projName }
    $projPRs     = ($projRepos | ForEach-Object { [int]$_["pr-count"] } | Measure-Object -Sum).Sum

    @{
        "org"            = $AdoOrg
        "teamproject"    = $projName
        "url"            = "$baseUrl/$projName"
        "repo-count"     = $projRepos.Count
        "pipeline-count" = $projPipes.Count
        "pr-count"       = $projPRs
    }
}

Write-Csv `
    -Path (Join-Path $OutputDir "team-projects.csv") `
    -Headers @("org","teamproject","url","repo-count","pipeline-count","pr-count") `
    -Rows $teamProjectRows

# -- repos.csv --
$repoRows = $allRepos | ForEach-Object {
    @{
        "org"                             = $_["org"]
        "teamproject"                     = $_["teamproject"]
        "repo"                            = $_["repo"]
        "url"                             = $_["url"]
        "last-push-date"                  = $_["last-push-date"]
        "pipeline-count"                  = $_["pipeline-count"]
        "compressed-repo-size-in-bytes"   = $_["compressed-repo-size-in-bytes"]
        "most-active-contributor"         = $_["most-active-contributor"]
        "pr-count"                        = $_["pr-count"]
        "commits-past-year"               = $_["commits-past-year"]
    }
}

Write-Csv `
    -Path (Join-Path $OutputDir "repos.csv") `
    -Headers @("org","teamproject","repo","url","last-push-date","pipeline-count","compressed-repo-size-in-bytes","most-active-contributor","pr-count","commits-past-year") `
    -Rows $repoRows

# -- pipelines.csv --
# Includes a bonus "is-cross-project" column not in the original ado2gh output
# so you can immediately see which pipelines were previously invisible
Write-Csv `
    -Path (Join-Path $OutputDir "pipelines.csv") `
    -Headers @("org","pipeline-project","pipeline-name","pipeline-id","pipeline-url","repo-project","repo-name","repo-type","is-cross-project") `
    -Rows $allPipelines

Write-Host "`nDone. Files written to: $OutputDir"
Write-Host "  orgs.csv, team-projects.csv, repos.csv, pipelines.csv"
Write-Host "`nCross-project pipelines found: $(($allPipelines | Where-Object { $_['is-cross-project'] -eq 'true' }).Count)"
