[CmdletBinding()]
param(
    [string]$RepoToken = $env:INPUT_REPO_TOKEN
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-EventPayload {
    $eventPath = $env:GITHUB_EVENT_PATH

    if ([string]::IsNullOrWhiteSpace($eventPath)) {
        throw 'GITHUB_EVENT_PATH is not set.'
    }

    if (-not (Test-Path -LiteralPath $eventPath)) {
        throw "Event payload file was not found: $eventPath"
    }

    return Get-Content -LiteralPath $eventPath -Raw | ConvertFrom-Json
}

function Get-PullRequestContext {
    $payload = Get-EventPayload

    if ($null -eq $payload.pull_request) {
        throw 'This action must run on a pull request event.'
    }

    if ($null -eq $payload.repository -or $null -eq $payload.repository.owner) {
        throw 'Repository information is missing from the event payload.'
    }

    return [pscustomobject]@{
        Owner = [string]$payload.repository.owner.login
        Repo = [string]$payload.repository.name
        Number = [int]$payload.pull_request.number
        InitialDescription = [string]$payload.pull_request.body
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
        throw 'repo-token input is required.'
    }

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw 'GitHub CLI (gh) is required but was not found on PATH.'
    }

    $previousGhToken = $env:GH_TOKEN

    try {
        $env:GH_TOKEN = $Token
        $bodyLines = & gh api "repos/$Owner/$Repo/pulls/$PullRequestNumber" --jq '.body'

        if ($LASTEXITCODE -ne 0) {
            throw 'Failed to fetch pull request description using gh api.'
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

function Get-MatchingWorkItemLink {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Description
    )

    $linkPattern = '\[(?<text>[^\[\]]+)\]\((?<url>[^)\r\n]+)\)'

    foreach ($match in [regex]::Matches($Description, $linkPattern)) {
        $text = $match.Groups['text'].Value.Trim()
        $url = $match.Groups['url'].Value.Trim()

        if ($text -match '^AB#\d+$' -and $url.IndexOf('/_workitems/edit/', [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return [pscustomobject]@{
                Text = $text
                Url = $url
            }
        }
    }

    return $null
}

function Test-WorkItemLinkDescription {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Description
    )

    return $null -ne (Get-MatchingWorkItemLink -Description $Description)
}

function Invoke-LinkCheck {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$InitialDescription,

        [Parameter(Mandatory = $true)]
        [scriptblock]$DescriptionProvider,

        [int]$RetryDelaySeconds = 10
    )

    if (Test-WorkItemLinkDescription -Description $InitialDescription) {
        Write-Host 'Pull request description already contains a valid Azure Boards link.'
        return
    }

    Write-Host "Initial check failed. Waiting $RetryDelaySeconds seconds before rechecking."
    Start-Sleep -Seconds $RetryDelaySeconds

    $updatedDescription = & $DescriptionProvider

    if (Test-WorkItemLinkDescription -Description $updatedDescription) {
        Write-Host 'Pull request description contains a valid Azure Boards link after retry.'
        return
    }

    throw 'Pull request description must contain a markdown link with text like [AB#123] and a target URL containing /_workitems/edit/.'
}

function Invoke-Action {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Token
    )

    $context = Get-PullRequestContext

    Write-Host "Checking pull request #$($context.Number) in $($context.Owner)/$($context.Repo)."

    $descriptionProvider = {
        Get-PullRequestDescriptionFromGitHub -Token $Token -Owner $context.Owner -Repo $context.Repo -PullRequestNumber $context.Number
    }.GetNewClosure()

    Invoke-LinkCheck -InitialDescription $context.InitialDescription -DescriptionProvider $descriptionProvider
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Action -Token $RepoToken
}