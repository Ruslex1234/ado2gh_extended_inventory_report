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
    param(
        [string]$Message,
        [switch]$Success
    )

    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    if ($Success) {
        Write-Host "[$ts] [INFO] $Message" -ForegroundColor Green
    }
    else {
        Write-Host "[$ts] [INFO] $Message"
    }
}

function Get-AuthHeader {
    $token = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$AdoPat"))
    return @{
        Authorization = "Basic $token"
        "Content-Type" = "application/json"
    }
}

function Get-ProjectSegment {
    param([string]$ProjectName)
    return [Uri]::EscapeDataString($ProjectName)
}

function Invoke-AdoApi {
    param (
        [string]$Url,
        [hashtable]$Headers = (Get-AuthHeader)
    )

    try {
        return Invoke-RestMethod -Uri $Url -Headers $Headers -Method Get
    }
    catch {
        Write-Warning "API call failed: $Url`n$($_.Exception.Message)"
        return $null
    }
}

function Invoke-AdoApiPostJson {
    param (
        [string]$Url,
        [object]$Body,
        [hashtable]$Headers = (Get-AuthHeader)
    )

    try {
        $json = $Body | ConvertTo-Json -Depth 20
        return Invoke-RestMethod -Uri $Url -Headers $Headers -Method Post -Body $json -ContentType "application/json"
    }
    catch {
        Write-Warning "API POST failed: $Url`n$($_.Exception.Message)"
        return $null
    }
}

function ConvertTo-ObjectArray {
    param($InputObject)

    if ($null -eq $InputObject) {
        return @()
    }

    if ($InputObject -is [System.Array]) {
        return @($InputObject)
    }

    if ($InputObject -is [System.Collections.IList]) {
        return @($InputObject)
    }

    return @($InputObject)
}

function Get-PropValue {
    param(
        $Object,
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    if ($Object -is [hashtable]) {
        if ($Object.ContainsKey($Name)) {
            return $Object[$Name]
        }
        return $null
    }

    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) {
        return $prop.Value
    }

    return $null
}

function Get-NestedStringValue {
    param(
        $Object,
        [string[]]$Path
    )

    $current = $Object
    foreach ($part in $Path) {
        if ($null -eq $current) {
            return ""
        }
        $current = Get-PropValue -Object $current -Name $part
    }

    if ($null -eq $current) {
        return ""
    }

    # Handle ADO property-bag values like:
    # { "$value": "something" } or { "value": "something" }
    if ($current -isnot [string]) {
        $dollarValue = Get-PropValue -Object $current -Name '$value'
        if ($null -ne $dollarValue) {
            return [string]$dollarValue
        }

        $plainValue = Get-PropValue -Object $current -Name 'value'
        if ($null -ne $plainValue) {
            return [string]$plainValue
        }
    }

    return [string]$current
}

function Get-AllPages {
    param (
        [string]$BaseUrl,
        [hashtable]$Headers = (Get-AuthHeader),
        [string]$ValueProperty = "value",
        [string]$TopParameter = '$top',
        [string]$SkipParameter = '$skip'
    )

    $results   = [System.Collections.Generic.List[object]]::new()
    $separator = if ($BaseUrl -match "\?") { "&" } else { "?" }
    $top  = 200
    $skip = 0

    do {
        $url = "{0}{1}{2}={3}&{4}={5}" -f $BaseUrl, $separator, $TopParameter, $top, $SkipParameter, $skip
        $response = Invoke-AdoApi -Url $url -Headers $Headers
        if ($null -eq $response) {
            break
        }

        $pageRaw = if ($response.PSObject.Properties[$ValueProperty]) { $response.$ValueProperty } else { $null }
        $page    = @(ConvertTo-ObjectArray $pageRaw)

        # Avoid @($null).Count = 1 issue
        $page = @($page | Where-Object { $null -ne $_ })

        if ($page.Count -eq 0) {
            break
        }

        foreach ($item in $page) {
            [void]$results.Add($item)
        }

        $skip += $page.Count

        if ($page.Count -lt $top) {
            break
        }
    }
    while ($true)

    return ,([object[]]$results)
}

function Get-CommitStatsPastYear {
    param(
        [string]$BaseUrl,
        [string]$ProjectSegment,
        [string]$RepoId,
        [hashtable]$Headers
    )

    $repoIdEsc = [Uri]::EscapeDataString($RepoId)
    $url = "$BaseUrl/$ProjectSegment/_apis/git/repositories/$repoIdEsc/commitsbatch?api-version=7.1"

    $fromDate = [DateTime]::UtcNow.AddYears(-1).ToString("o")
    $skip = 0
    $top  = 200

    $allCommits = [System.Collections.Generic.List[object]]::new()

    do {
        $body = @{
            searchCriteria = @{
                fromDate = $fromDate
                '$top'   = $top
                '$skip'  = $skip
            }
        }

        $response = Invoke-AdoApiPostJson -Url $url -Body $body -Headers $Headers
        if ($null -eq $response) {
            break
        }

        $page = @()
        if ($response.PSObject.Properties['value']) {
            $page = @(ConvertTo-ObjectArray $response.value | Where-Object { $null -ne $_ })
        }

        if ($page.Count -eq 0) {
            break
        }

        foreach ($commit in $page) {
            [void]$allCommits.Add($commit)
        }

        $skip += $page.Count

        if ($page.Count -lt $top) {
            break
        }
    }
    while ($true)

    $topContributor = ""
    if ($allCommits.Count -gt 0) {
        $top1 = $allCommits |
            Where-Object { $_.PSObject.Properties['author'] -and $_.author } |
            Group-Object {
                if ($_.author.PSObject.Properties['name'] -and $_.author.name) {
                    [string]$_.author.name
                }
                elseif ($_.author.PSObject.Properties['email'] -and $_.author.email) {
                    [string]$_.author.email
                }
                else {
                    "__blank__"
                }
            } |
            Where-Object { $_.Name -ne "__blank__" } |
            Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, @{ Expression = 'Name'; Descending = $false } |
            Select-Object -First 1

        if ($top1) {
            $topContributor = $top1.Name
        }
    }

    return @{
        Count = $allCommits.Count
        TopContributor = $topContributor
    }
}

function Resolve-BuildRepository {
    param(
        [string]$PipelineProject,
        $Definition,
        [string]$BaseUrl,
        [hashtable]$Headers,
        [hashtable]$RepoIdToProject,
        [hashtable]$RepoIdToName,
        [object[]]$AllRepos
    )

    $repoType    = ""
    $repoProject = $PipelineProject
    $repoName    = ""
    $repoId      = ""

    $defRepo = Get-PropValue -Object $Definition -Name 'repository'
    $defId   = Get-PropValue -Object $Definition -Name 'id'

    # Always fetch the full definition for stronger cross-project resolution.
    $fullDef = $null
    if ($defId) {
        $pipelineProjSeg = Get-ProjectSegment -ProjectName $PipelineProject
        $fullDef = Invoke-AdoApi -Url "$BaseUrl/$pipelineProjSeg/_apis/build/definitions/${defId}?api-version=7.1" -Headers $Headers
    }

    $candidateRepos = @()
    if ($defRepo) {
        $candidateRepos += $defRepo
    }

    $fullRepo = Get-PropValue -Object $fullDef -Name 'repository'
    if ($fullRepo) {
        $candidateRepos += $fullRepo
    }

    foreach ($repo in $candidateRepos) {
        if (-not $repo) {
            continue
        }

        if (-not $repoType) {
            $v = Get-NestedStringValue -Object $repo -Path @('type')
            if ($v) {
                $repoType = $v
            }
        }

        if (-not $repoId) {
            $v = Get-NestedStringValue -Object $repo -Path @('id')
            if ($v) {
                $repoId = $v.ToLower()
            }
        }

        if (-not $repoName) {
            $v = Get-NestedStringValue -Object $repo -Path @('name')
            if ($v) {
                $repoName = $v
            }
        }

        $projectName = Get-NestedStringValue -Object $repo -Path @('project', 'name')
        if ($projectName) {
            $repoProject = $projectName
        }

        if (-not $repoName) {
            foreach ($path in @(
                @('properties', 'fullName'),
                @('properties', 'repositoryName'),
                @('properties', 'name')
            )) {
                $v = Get-NestedStringValue -Object $repo -Path $path
                if ($v) {
                    $repoName = $v
                    break
                }
            }
        }

        if (-not $repoProject -or $repoProject -eq $PipelineProject) {
            foreach ($path in @(
                @('properties', 'projectName'),
                @('properties', 'teamProject')
            )) {
                $v = Get-NestedStringValue -Object $repo -Path $path
                if ($v) {
                    $repoProject = $v
                    break
                }
            }
        }
    }

    # If the repo name comes back as "Project/Repo", split it.
    if ($repoName -match '^([^/]+)/(.+)$') {
        $prefixProject = $Matches[1]
        $suffixRepo    = $Matches[2]

        if (-not $repoProject -or $repoProject -eq $PipelineProject) {
            $repoProject = $prefixProject
        }

        $repoName = $suffixRepo
    }

    # Strongest match: repo ID -> actual project/name from inventory
    if ($repoId -and $RepoIdToProject.ContainsKey($repoId)) {
        $repoProject = $RepoIdToProject[$repoId]
        if ($RepoIdToName.ContainsKey($repoId)) {
            $repoName = $RepoIdToName[$repoId]
        }
    }

    # Fallback to abbreviated repo info if still blank
    if (-not $repoName -and $defRepo) {
        $fallbackName = Get-NestedStringValue -Object $defRepo -Path @('name')
        if ($fallbackName) {
            if ($fallbackName -match '^([^/]+)/(.+)$') {
                if (-not $repoProject -or $repoProject -eq $PipelineProject) {
                    $repoProject = $Matches[1]
                }
                $repoName = $Matches[2]
            }
            else {
                $repoName = $fallbackName
            }
        }
    }

    # Last-resort recovery using repo name against known repos
    if ($repoName) {
        $sameProjectKey = "$PipelineProject/$repoName"
        $sameProjectHit = $AllRepos | Where-Object { $_["_repoKey"] -eq $sameProjectKey } | Select-Object -First 1

        if ($sameProjectHit) {
            $repoProject = $sameProjectHit["_projName"]
            $repoName    = $sameProjectHit["repo"]
        }
        else {
            $globalHit = $AllRepos | Where-Object { $_["repo"] -eq $repoName } | Select-Object -First 1
            if ($globalHit) {
                if (-not $repoProject) {
                    $repoProject = $globalHit["_projName"]
                }
                $repoName = $globalHit["repo"]
            }
        }
    }

    if (-not $repoProject) {
        $repoProject = $PipelineProject
    }

    $isCrossProject = ($repoType -eq "TfsGit") -and (-not [string]::IsNullOrWhiteSpace($repoName)) -and ($repoProject -ne $PipelineProject)
    $crossProjectRepo = if ($isCrossProject) { "$repoProject/$repoName" } else { "" }

    return @{
        RepoType         = $repoType
        RepoProject      = $repoProject
        RepoName         = $repoName
        CrossProjectRepo = $crossProjectRepo
    }
}

function ConvertTo-CsvSafe {
    param([string]$Value)

    if ($null -eq $Value) {
        return ""
    }

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

if (Test-Path -LiteralPath $OutputDir) {
    $OutputDir = (Resolve-Path -LiteralPath $OutputDir).Path
}
else {
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
if ($null -eq $projectsResponse) {
    throw "Failed to fetch projects from $baseUrl"
}

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
    $projName = [string]$project.name
    $projSeg  = Get-ProjectSegment -ProjectName $projName

    $repos = Get-AllPages -BaseUrl "$baseUrl/$projSeg/_apis/git/repositories?api-version=7.1" -Headers $headers

    foreach ($repo in $repos) {
        $repoName = [string]$repo.name
        $repoKey  = "$projName/$repoName"
        $repoUrl  = [string]$repo.remoteUrl

        # ADO repository size is returned in KB
        $sizeBytes = 0
        if ($repo.PSObject.Properties['size'] -and $repo.size) {
            $sizeBytes = [int64]$repo.size * 1KB
        }

        # Last push date
        $lastPush = ""
        $repoIdEsc = [Uri]::EscapeDataString([string]$repo.id)
        $pushesList = Invoke-AdoApi -Url "$baseUrl/$projSeg/_apis/git/repositories/$repoIdEsc/pushes?api-version=7.1&`$top=1" -Headers $headers
        if ($pushesList -and $pushesList.PSObject.Properties['value']) {
            $pushValues = @(ConvertTo-ObjectArray $pushesList.value)
            if ($pushValues.Count -gt 0 -and $pushValues[0] -and $pushValues[0].PSObject.Properties['date']) {
                $lastPush = [string]$pushValues[0].date
            }
        }

        # Accurate PR count
        $prAll = @(
            Get-AllPages `
                -BaseUrl "$baseUrl/$projSeg/_apis/git/repositories/$([Uri]::EscapeDataString([string]$repo.id))/pullrequests?api-version=7.1&searchCriteria.status=all" `
                -Headers $headers
        )
        $prCount = @($prAll | Where-Object { $null -ne $_ }).Count

        # Accurate commits in past year + most active contributor
        $commitStats = Get-CommitStatsPastYear `
            -BaseUrl $baseUrl `
            -ProjectSegment $projSeg `
            -RepoId ([string]$repo.id) `
            -Headers $headers

        $commitsPastYear = [int]$commitStats.Count
        $topContributor  = [string]$commitStats.TopContributor

        $normalizedId = if ($repo.PSObject.Properties['id'] -and $repo.id) {
            ([string]$repo.id).ToLower()
        }
        else {
            ""
        }

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
            "pipeline-count"                = 0
            "compressed-repo-size-in-bytes" = $sizeBytes
            "most-active-contributor"       = $topContributor
            "pr-count"                      = $prCount
            "commits-past-year"             = $commitsPastYear
        })
    }
}

Write-Log "Found $($allRepos.Count) Repos"

# Build lookup maps with lowercase IDs for reliable matching
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
    $projName = [string]$project.name
    $projSeg  = Get-ProjectSegment -ProjectName $projName

    $defs = Get-AllPages -BaseUrl "$baseUrl/$projSeg/_apis/build/definitions?api-version=7.1&queryOrder=definitionNameAscending" -Headers $headers

    foreach ($def in $defs) {
        $pipelineName = [string]$def.name
        $pipelineId   = [string]$def.id
        $pipelineUrl  = "$baseUrl/$projSeg/_build/definition?definitionId=$pipelineId"

        $resolved = Resolve-BuildRepository `
            -PipelineProject $projName `
            -Definition $def `
            -BaseUrl $baseUrl `
            -Headers $headers `
            -RepoIdToProject $repoIdToProject `
            -RepoIdToName $repoIdToName `
            -AllRepos @($allRepos)

        $repoProject      = $resolved.RepoProject
        $repoName         = $resolved.RepoName
        $crossProjectRepo = $resolved.CrossProjectRepo
        $repoType         = $resolved.RepoType

        $repoKey = if ($repoProject -and $repoName) { "$repoProject/$repoName" } else { "" }
        if ($repoKey -and $repoPipelineMap.ContainsKey($repoKey)) {
            $repoPipelineMap[$repoKey].Add($pipelineName)
        }

        if ($repoType -eq "TfsGit" -and [string]::IsNullOrWhiteSpace($repoName)) {
            Write-Warning "Could not resolve repository name for pipeline '$pipelineName' in project '$projName'."
        }

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
$teamProjectRows = @(
    foreach ($project in $projects) {
        $projName  = [string]$project.name
        $projRepos = @($allRepos     | Where-Object { $_["_projName"]   -eq $projName })
        $projPipes = @($allPipelines | Where-Object { $_["teamproject"] -eq $projName })
        $projPRs   = ($projRepos | ForEach-Object { [int]$_["pr-count"] } | Measure-Object -Sum).Sum

        @{
            "org"            = $AdoOrg
            "teamproject"    = $projName
            "url"            = "$baseUrl/$(Get-ProjectSegment -ProjectName $projName)"
            "repo-count"     = $projRepos.Count
            "pipeline-count" = $projPipes.Count
            "pr-count"       = $projPRs
        }
    }
)

Write-Log "Generating team-projects.csv..."
Write-Csv `
    -Path    (Join-Path $OutputDir "team-projects.csv") `
    -Headers @("org","teamproject","url","repo-count","pipeline-count","pr-count") `
    -Rows    $teamProjectRows
Write-Log "team-projects.csv generated" -Success

# -- repos.csv --
$repoRows = @(
    $allRepos | ForEach-Object {
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
    }
)

Write-Log "Generating repos.csv..."
Write-Csv `
    -Path    (Join-Path $OutputDir "repos.csv") `
    -Headers @("org","teamproject","repo","url","last-push-date","pipeline-count","compressed-repo-size-in-bytes","most-active-contributor","pr-count","commits-past-year") `
    -Rows    $repoRows
Write-Log "repos.csv generated" -Success

# -- pipelines.csv --
Write-Log "Generating pipelines.csv..."
Write-Csv `
    -Path    (Join-Path $OutputDir "pipelines.csv") `
    -Headers @("org","teamproject","repo","pipeline","url","cross-project-repo") `
    -Rows    @($allPipelines)
Write-Log "pipelines.csv generated" -Success
