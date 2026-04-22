<#
.SYNOPSIS
    Generates an ADO inventory report equivalent to `gh ado2gh inventory-report`
    but with full cross-project pipeline awareness.

.DESCRIPTION
    Produces four CSV files:
        orgs.csv            - Organization-level summary
        team-projects.csv   - Per-project summary
        repos.csv           - Per-repo details with accurate pipeline counts
        pipelines.csv       - All pipelines in ado2gh format, with an extra
                              cross-project-repo column for cross-project refs

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

function Write-Log {
    param([string]$Message, [switch]$Success)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    if ($Success) {
        Write-Host "[$ts] [INFO] $Message" -ForegroundColor Green
    } else {
        Write-Host "[$ts] [INFO] $Message"
    }
}

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
    param (
        [string]$BaseUrl,
        [hashtable]$Headers = (Get-AuthHeader),
        [string]$ValueProperty = "value"
    )
    $results   = [System.Collections.Generic.List[object]]::new()
    $separator = if ($BaseUrl -match "\?") { "&" } else { "?" }
    $top  = 200
    $skip = 0

    do {
        $url      = "${BaseUrl}${separator}`$top=${top}&`$skip=${skip}"
        $response = Invoke-AdoApi -Url $url -Headers $Headers
        if ($null -eq $response) { break }

        # @() wrapping guarantees an array with a valid .Count in strict mode,
        # even when a single-item ADO response deserialises as a bare PSCustomObject.
        $pageRaw = if ($response.PSObject.Properties[$ValueProperty]) { $response.$ValueProperty } else { $null }
        $page    = @($pageRaw)
        if ($page.Count -eq 0) { break }

        $results.AddRange($page)
        $skip += $page.Count

        if ($page.Count -lt $top) { break }
    } while ($true)

    # , [object[]] prevents PowerShell from unrolling the list on return.
    # Without this, a 1-item result comes back as a bare PSCustomObject with
    # no .Count property, which throws under Set-StrictMode -Version Latest.
    return , [object[]]$results
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

$baseUrl = "https://dev.azure.com/$AdoOrg"
$headers = Get-AuthHeader

Write-Log "ADO ORG: $AdoOrg"
Write-Log "Creating inventory report..."

# ---------------------------------------------------------------------------
# 1. Fetch all team projects
# ---------------------------------------------------------------------------

Write-Log "Finding Orgs..."
$projectsResponse = Invoke-AdoApi -Url "$baseUrl/_apis/projects?api-version=7.1&`$top=500" -Headers $headers
if ($null -eq $projectsResponse) { throw "Failed to fetch projects from $baseUrl" }
$projects = @($projectsResponse.value)
Write-Log "Found 1 Orgs"
Write-Log "Finding Team Projects..."
Write-Log "Found $($projects.Count) Team Projects"

# ---------------------------------------------------------------------------
# 2. Fetch repos per project + accurate stats
# ---------------------------------------------------------------------------

Write-Log "Finding Repos..."

$allRepos        = [System.Collections.Generic.List[hashtable]]::new()
$repoPipelineMap = @{}   # "ProjectName/RepoName" -> List[string] of pipeline names

foreach ($project in $projects) {
    $projName = $project.name
    $repos    = Get-AllPages -BaseUrl "$baseUrl/$projName/_apis/git/repositories?api-version=7.1" -Headers $headers

    foreach ($repo in $repos) {
        $repoName = $repo.name
        $repoKey  = "$projName/$repoName"
        $repoUrl  = $repo.remoteUrl

        # Size (bytes) — ADO returns KB in repo.size
        $sizeBytes = 0
        if ($repo.PSObject.Properties['size'] -and $repo.size) { $sizeBytes = $repo.size * 1KB }

        # Last push date
        $lastPush   = ""
        $pushesList = Invoke-AdoApi -Url "$baseUrl/$projName/_apis/git/repositories/$($repo.id)/pushes?api-version=7.1&`$top=1" -Headers $headers
        if ($pushesList -and $pushesList.PSObject.Properties['value']) {
            $pushValues = @($pushesList.value)
            if ($pushValues.Count -gt 0 -and $pushValues[0].PSObject.Properties['date']) {
                $lastPush = [string]$pushValues[0].date
            }
        }

        # PR count — paginate to get the accurate total (response.count is only page count)
        $prAll   = @(Get-AllPages -BaseUrl "$baseUrl/$projName/_apis/git/repositories/$($repo.id)/pullrequests?api-version=7.1&searchCriteria.status=all" -Headers $headers)
        $prCount = $prAll.Count

        # Commits in the past year — used for both commits-past-year and most-active-contributor
        $yearAgo     = (Get-Date).AddYears(-1).ToString("yyyy-MM-dd")
        $yearCommits = @(Get-AllPages -BaseUrl "$baseUrl/$projName/_apis/git/repositories/$($repo.id)/commits?api-version=7.1&searchCriteria.fromDate=$yearAgo" -Headers $headers)
        $commitsPastYear = $yearCommits.Count

        $topContributor = ""
        if ($yearCommits.Count -gt 0) {
            $top1 = $yearCommits |
                Where-Object  { $_.PSObject.Properties['author'] -and $_.author.PSObject.Properties['name'] } |
                Group-Object  { [string]$_.author.name } |
                Sort-Object   Count -Descending |
                Select-Object -First 1
            if ($top1) { $topContributor = $top1.Name }
        }

        # Normalize GUID to lowercase for reliable cross-API matching in step 3
        $normalizedId = if ($repo.PSObject.Properties['id'] -and $repo.id) { $repo.id.ToLower() } else { "" }

        $repoPipelineMap[$repoKey] = [System.Collections.Generic.List[string]]::new()

        $allRepos.Add(@{
            _projName   = $projName
            _repoKey    = $repoKey
            _repoId     = $normalizedId
            org         = $AdoOrg
            teamproject = $projName
            repo        = $repoName
            url         = $repoUrl
            "last-push-date"                = $lastPush
            "pipeline-count"                = 0       # back-filled in step 4
            "compressed-repo-size-in-bytes" = $sizeBytes
            "most-active-contributor"       = $topContributor
            "pr-count"                      = $prCount
            "commits-past-year"             = $commitsPastYear
        })
    }
}

Write-Log "Found $($allRepos.Count) Repos"

# Build lookup maps with lowercase IDs for reliable matching against build definitions
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
# 3. Fetch ALL pipelines from ALL projects with cross-project repo resolution
# ---------------------------------------------------------------------------

Write-Log "Finding Pipelines..."

$allPipelines = [System.Collections.Generic.List[hashtable]]::new()

foreach ($project in $projects) {
    $projName = $project.name
    $defs     = Get-AllPages -BaseUrl "$baseUrl/$projName/_apis/build/definitions?api-version=7.1&queryOrder=definitionNameAscending" -Headers $headers

    foreach ($def in $defs) {
        $pipelineName = $def.name
        $pipelineId   = $def.id
        $pipelineUrl  = "$baseUrl/$projName/_build/definition?definitionId=$pipelineId"

        $repoProject = $projName
        $repoName    = ""
        $repoType    = ""

        $repoInfo = if ($def.PSObject.Properties['repository']) { $def.repository } else { $null }
        if ($repoInfo) {
            $repoType    = if ($repoInfo.PSObject.Properties['type']) { [string]$repoInfo.type } else { "" }
            $defRepoName = if ($repoInfo.PSObject.Properties['name']) { [string]$repoInfo.name } else { "" }
            # Normalize GUID case — the build definitions API and repos API can differ
            $defRepoId   = if ($repoInfo.PSObject.Properties['id'] -and $repoInfo.id) { $repoInfo.id.ToLower() } else { "" }

            if ($repoType -eq "TfsGit") {
                $resolved = $false

                # Resolution 1: exact ID match (fast — no extra API call)
                if ($defRepoId -and $repoIdToProject.ContainsKey($defRepoId)) {
                    $repoProject = $repoIdToProject[$defRepoId]
                    $repoName    = $repoIdToName[$defRepoId]
                    $resolved    = $true
                }

                # Resolution 2: name match within the pipeline's own project
                # Handles the case where repository.id is absent from the abbreviated response
                if (-not $resolved -and $defRepoName -and $repoPipelineMap.ContainsKey("$projName/$defRepoName")) {
                    $repoProject = $projName
                    $repoName    = $defRepoName
                    $resolved    = $true
                }

                if (-not $resolved) {
                    # Resolution 3: fetch full definition for cross-project cases
                    $fullDef = Invoke-AdoApi -Url "$baseUrl/$projName/_apis/build/definitions/${pipelineId}?api-version=7.1" -Headers $headers
                    if ($fullDef) {
                        $fullRepo = if ($fullDef.PSObject.Properties['repository']) { $fullDef.repository } else { $null }
                        $projProp = if ($fullRepo -and $fullRepo.PSObject.Properties['project']) { $fullRepo.project } else { $null }
                        if ($projProp -and $projProp.PSObject.Properties['name']) {
                            $repoProject = [string]$projProp.name
                            $resolved    = $true
                        }
                        if ($fullRepo -and $fullRepo.PSObject.Properties['name']) {
                            $fn = [string]$fullRepo.name
                            # Strip "ProjectName/" prefix if present
                            $repoName = if ($fn -match '^[^/]+/(.+)$') { $Matches[1] } else { $fn }
                        }
                    }

                    # Resolution 4: name match across all projects (last resort)
                    if (-not $resolved -and $defRepoName) {
                        $xMatch = $allRepos | Where-Object { $_["repo"] -eq $defRepoName } | Select-Object -First 1
                        if ($xMatch) {
                            $repoProject = $xMatch["_projName"]
                            $repoName    = $defRepoName
                        } else {
                            $repoName = $defRepoName
                        }
                    }
                }
            } else {
                # Non-TfsGit (GitHub, external Git, etc.) — keep as-is
                $repoName = $defRepoName
            }
        }

        $repoKey = "$repoProject/$repoName"
        if ($repoPipelineMap.ContainsKey($repoKey)) {
            $repoPipelineMap[$repoKey].Add($pipelineName)
        }

        # cross-project-repo: blank for same-project, "ProjectName/RepoName" for cross-project
        $isCrossProject   = ($repoType -eq "TfsGit") -and ($repoProject -ne $projName)
        $crossProjectRepo = if ($isCrossProject) { "$repoProject/$repoName" } else { "" }

        $allPipelines.Add(@{
            org                  = $AdoOrg
            teamproject          = $projName
            repo                 = $repoName
            pipeline             = $pipelineName
            url                  = $pipelineUrl
            "cross-project-repo" = $crossProjectRepo
        })
    }
}

Write-Log "Found $($allPipelines.Count) Pipelines"

# ---------------------------------------------------------------------------
# 4. Back-fill pipeline-count into repo rows
# ---------------------------------------------------------------------------

foreach ($repo in $allRepos) {
    $key = $repo["_repoKey"]
    if ($repoPipelineMap.ContainsKey($key)) {
        $repo["pipeline-count"] = $repoPipelineMap[$key].Count
    }
}

# ---------------------------------------------------------------------------
# 5. Write CSVs
# ---------------------------------------------------------------------------

# -- orgs.csv --
$orgRow = @{
    "name"              = $AdoOrg
    "url"               = "https://dev.azure.com/$AdoOrg"
    "owner"             = $AdoOrg
    "teamproject-count" = $projects.Count
    "repo-count"        = $allRepos.Count
    "pipeline-count"    = $allPipelines.Count
    "is-pat-org-admin"  = "unknown"
    "pr-count"          = ($allRepos | ForEach-Object { [int]$_["pr-count"] } | Measure-Object -Sum).Sum
}

Write-Log "Generating orgs.csv..."
Write-Csv `
    -Path    (Join-Path $OutputDir "orgs.csv") `
    -Headers @("name","url","owner","teamproject-count","repo-count","pipeline-count","is-pat-org-admin","pr-count") `
    -Rows    @($orgRow)
Write-Log "orgs.csv generated" -Success

# -- team-projects.csv --
$teamProjectRows = @(foreach ($project in $projects) {
    $projName  = $project.name
    $projRepos = @($allRepos     | Where-Object { $_["_projName"]  -eq $projName })
    $projPipes = @($allPipelines | Where-Object { $_["teamproject"] -eq $projName })
    $projPRs   = ($projRepos | ForEach-Object { [int]$_["pr-count"] } | Measure-Object -Sum).Sum

    @{
        "org"            = $AdoOrg
        "teamproject"    = $projName
        "url"            = "$baseUrl/$projName"
        "repo-count"     = $projRepos.Count
        "pipeline-count" = $projPipes.Count
        "pr-count"       = $projPRs
    }
})

Write-Log "Generating teamprojects.csv..."
Write-Csv `
    -Path    (Join-Path $OutputDir "team-projects.csv") `
    -Headers @("org","teamproject","url","repo-count","pipeline-count","pr-count") `
    -Rows    $teamProjectRows
Write-Log "team-projects.csv generated" -Success

# -- repos.csv --
$repoRows = @($allRepos | ForEach-Object {
    @{
        "org"                           = $_["org"]
        "teamproject"                   = $_["teamproject"]
        "repo"                          = $_["repo"]
        "url"                           = $_["url"]
        "last-push-date"                = $_["last-push-date"]
        "pipeline-count"                = $_["pipeline-count"]
        "compressed-repo-size-in-bytes" = $_["compressed-repo-size-in-bytes"]
        "most-active-contributor"       = $_["most-active-contributor"]
        "pr-count"                      = $_["pr-count"]
        "commits-past-year"             = $_["commits-past-year"]
    }
})

Write-Log "Generating repos.csv..."
Write-Csv `
    -Path    (Join-Path $OutputDir "repos.csv") `
    -Headers @("org","teamproject","repo","url","last-push-date","pipeline-count","compressed-repo-size-in-bytes","most-active-contributor","pr-count","commits-past-year") `
    -Rows    $repoRows
Write-Log "repos.csv generated" -Success

# -- pipelines.csv --
# Matches ado2gh column order: org, teamproject, repo, pipeline, url
# Plus one extension column: cross-project-repo (blank when repo lives in the
# same project as the pipeline; "ProjectName/RepoName" when it does not)
Write-Log "Generating pipelines.csv..."
Write-Csv `
    -Path    (Join-Path $OutputDir "pipelines.csv") `
    -Headers @("org","teamproject","repo","pipeline","url","cross-project-repo") `
    -Rows    @($allPipelines)
Write-Log "pipelines.csv generated" -Success
