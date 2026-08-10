[CmdletBinding()]
param(
    [string]$RepoToken = $env:INPUT_REPO_TOKEN
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-EventPayload {
    $eventPath = $env:GITHUB_EVENT_PATH

    if ([string]::IsNullOrWhiteSpace($eventPath)) {
        Write-ActionError -Title 'Missing GitHub event payload' -Message 'GITHUB_EVENT_PATH is not set.'
    }

    if (-not (Test-Path -LiteralPath $eventPath)) {
        Write-ActionError -Title 'Missing GitHub event payload' -Message "Event payload file was not found: $eventPath"
    }

    return Get-Content -LiteralPath $eventPath -Raw | ConvertFrom-Json
}

function Get-PullRequestContext {
    $payload = Get-EventPayload

    if ($null -eq $payload.pull_request) {
        Write-ActionError -Title 'Invalid event type' -Message 'This action must run on a pull request event.'
    }

    if ($null -eq $payload.repository -or $null -eq $payload.repository.owner) {
        Write-ActionError -Title 'Invalid event payload' -Message 'Repository information is missing from the event payload.'
    }

    return @{
        Owner             = [string]$payload.repository.owner.login
        Repo              = [string]$payload.repository.name
        PullRequestNumber = [int]$payload.pull_request.number
    }
}

function Get-PullRequestDescriptionFromGitHub {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Token,

        [Parameter(Mandatory = $true)]
        [string]$Owner,

        [Parameter(Mandatory = $true)]
        [string]$Repo,

        [Parameter(Mandatory = $true)]
        [int]$PullRequestNumber
    )

    if ([string]::IsNullOrWhiteSpace($Token)) {
        Write-ActionError -Title 'Missing repo token' -Message 'repo-token input is required.'
    }

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-ActionError -Title 'Missing GitHub CLI' -Message 'GitHub CLI (gh) is required but was not found on PATH.'
    }

    $previousGhToken = $env:GH_TOKEN

    try {
        $env:GH_TOKEN = $Token
        $bodyLines = & gh api "repos/$Owner/$Repo/pulls/$PullRequestNumber" --jq '.body'

        if ($LASTEXITCODE -ne 0) {
            Write-ActionError -Title 'Failed to fetch pull request description' -Message 'Failed to fetch pull request description using gh api.'
        }

        return [string]($bodyLines -join "`n")
    }
    finally {
        if ([string]::IsNullOrWhiteSpace($previousGhToken)) {
            Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
        }
        else {
            $env:GH_TOKEN = $previousGhToken
        }
    }
}

function Write-ActionError {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [string]$Title = 'No valid work item link'
    )
    Write-Host "::error title=$Title::$Message"
    throw $Message
}

function Test-WorkItemText {
    [OutputType([Boolean])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Description
    )
    return $Description -match 'AB#\d+'
}

function Test-WorkItemLink {
    [OutputType([Boolean])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Description
    )
    return $Description -match '\[AB#\d+\]\([^\)\s]*\/_workitems\/edit\/\d+\/?(?:\?[^\)#\s]*)?(?:#[^\)\s]*)?\)'
}

function Test-PullRequestDescription {
    [OutputType([Boolean])]
    param(
        [hashtable]$PrContext,
        [string]$RepoToken
    )

    $description = Get-PullRequestDescriptionFromGitHub @PrContext -Token $RepoToken
    Write-Host "Pull request description fetched successfully"
    Write-Host "::group::Description:"
    Write-Host $description
    Write-Host "::endgroup::"

    Write-Host "Validating pull request description for Azure Boards work item link..."
    $hasWorkItemText = Test-WorkItemText -Description $description
    if (-not $hasWorkItemText) {
        Write-ActionError -Message 'Pull request description does not contain Azure Boards work item text (AB#<digits>).'
    }

    $hasWorkItemLink = Test-WorkItemLink -Description $description
    return $hasWorkItemLink
}

if ($MyInvocation.InvocationName -ne '.') {
    Write-Host "Fetching pull request description from GitHub..."
    $prContext = Get-PullRequestContext
    Write-Host "Pull request #$($prContext.PullRequestNumber) in $($prContext.Owner)/$($prContext.Repo)."

    $hasWorkItemLink = Test-PullRequestDescription -PrContext $prContext -RepoToken $RepoToken
    if ($hasWorkItemLink) {
        Write-Host "Pull request description contains a valid Azure Boards work item link."
        return
    }

    Write-Host "Pull request description does not contain a valid Azure Boards work item link. Waiting 10 seconds before rechecking..."
    Start-Sleep -Seconds 10
    Write-Host "Rechecking pull request description for Azure Boards work item link..."

    $hasWorkItemLink = Test-PullRequestDescription -PrContext $prContext -RepoToken $RepoToken
    if ($hasWorkItemLink) {
        Write-Host "Pull request description contains a valid Azure Boards work item link after retry."
        return
    }

    Write-ActionError -Message 'Pull request description does not contain a valid Azure Boards work item link.'
}
