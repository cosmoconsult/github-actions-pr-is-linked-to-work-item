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
        Owner              = [string]$payload.repository.owner.login
        Repo               = [string]$payload.repository.name
        Number             = [int]$payload.pull_request.number
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
<#
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

function Get-LinkValidationResult {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Description
    )

    if ([string]::IsNullOrWhiteSpace($Description)) {
        return [pscustomobject]@{
            IsValid = $false
            Reason  = 'Description is empty.'
        }
    }

    $linkPattern = '\[(?<text>[^\[\]]+)\]\((?<url>[^)\r\n]+)\)'
    $links = @([regex]::Matches($Description, $linkPattern))

    if ($links.Count -eq 0) {
        return [pscustomobject]@{
            IsValid = $false
            Reason  = 'No markdown links were found in the description.'
        }
    }

    $matchingLink = Get-MatchingWorkItemLink -Description $Description

    if ($null -ne $matchingLink) {
        return [pscustomobject]@{
            IsValid = $true
            Reason  = "Found valid Azure Boards link: [$($matchingLink.Text)]($($matchingLink.Url))."
        }
    }

    $hasAbText = $false
    $hasWorkItemUrl = $false

    foreach ($link in $links) {
        $text = $link.Groups['text'].Value.Trim()
        $url = $link.Groups['url'].Value.Trim()

        if ($text -match '^AB#\d+$') {
            $hasAbText = $true
        }

        if ($url.IndexOf('/_workitems/edit/', [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $hasWorkItemUrl = $true
        }
    }

    if ($hasAbText -and -not $hasWorkItemUrl) {
        return [pscustomobject]@{
            IsValid = $false
            Reason  = 'Found markdown link text like AB#123, but the link target does not contain /_workitems/edit/.'
        }
    }

    if (-not $hasAbText -and $hasWorkItemUrl) {
        return [pscustomobject]@{
            IsValid = $false
            Reason  = 'Found a link to /_workitems/edit/, but the markdown link text is not in AB#<digits> format.'
        }
    }

    return [pscustomobject]@{
        IsValid = $false
        Reason  = 'Markdown links exist, but none match [AB#<digits>](.../_workitems/edit/...).'
    }
}

function Test-WorkItemLinkDescription {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Description
    )

    return (Get-LinkValidationResult -Description $Description).IsValid
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

    $initialResult = Get-LinkValidationResult -Description $InitialDescription

    if ($initialResult.IsValid) {
        Write-Host 'Pull request description already contains a valid Azure Boards link.'
        return
    }

    Write-Host "Initial check failed: $($initialResult.Reason)"
    Write-Host "Waiting $RetryDelaySeconds seconds before rechecking."
    Start-Sleep -Seconds $RetryDelaySeconds

    $updatedDescription = & $DescriptionProvider
    $updatedResult = Get-LinkValidationResult -Description $updatedDescription

    if ($updatedResult.IsValid) {
        Write-Host 'Pull request description contains a valid Azure Boards link after retry.'
        return
    }

    $failureMessage = @(
        'Pull request description validation failed after one retry.'
        "Initial check: $($initialResult.Reason)"
        "Retry check: $($updatedResult.Reason)"
        'Expected format: [AB#123](https://dev.azure.com/<org>/<project>/_workitems/edit/123).'
    ) -join ' '

    throw $failureMessage
}

function Invoke-Action {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Token
    )

    $context = Get-PullRequestContext

    Write-Host "Checking pull request #$($context.Number) in $($context.Owner)/$($context.Repo)."

    $getDescriptionCommand = Get-Command -Name Get-PullRequestDescriptionFromGitHub -CommandType Function

    $descriptionProvider = {
        & $getDescriptionCommand -Token $Token -Owner $context.Owner -Repo $context.Repo -PullRequestNumber $context.Number
    }.GetNewClosure()

    Invoke-LinkCheck -InitialDescription $context.InitialDescription -DescriptionProvider $descriptionProvider
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Action -Token $RepoToken
}

#>

# Get Description
Write-Host "Fetching pull request description from GitHub..."
$PrContext = Get-PullRequestContext
Write-Host "Pull request #$($PrContext.Number) in $($PrContext.Owner)/$($PrContext.Repo)."

$Description = Get-PullRequestDescriptionFromGitHub -Owner $PrContext.Owner -Repo $PrContext.Repo -PullRequestNumber $PrContext.Number -Token $RepoToken
Write-Host "Pull request description fetched successfully: $Description"

Write-Host "Validating pull request description for Azure Boards work item link..."
$HasWorkItemText = $Description -match 'AB#\d+'
if (-not $HasWorkItemText) {
    Write-Host "::error title=No valid work item link::Pull request description does not contain Azure Boards work item text (AB#<digits>)."
    throw "Pull request description does not contain Azure Boards work item text (AB#<digits>)."
}

$HasWorkItemLink = $Description -match '\[AB#\d+\]\(.*\/_workitems\/edit\/\d+\/?\)'
if ($HasWorkItemLink) {
    Write-Host "Pull request description contains a valid Azure Boards work item link."
    return
}
if (!$HasWorkItemLink ) {
    Write-Host "Pull request description does not contain a valid Azure Boards work item link. Waiting 10 seconds before rechecking..."
    Start-Sleep -Seconds 10

    $Description = Get-PullRequestDescriptionFromGitHub -Owner $PrContext.Owner -Repo $PrContext.Repo -PullRequestNumber $PrContext.Number -Token $RepoToken
    Write-Host "Pull request description fetched successfully: $Description"

    Write-Host "Validating pull request description for Azure Boards work item link..."
    $HasWorkItemText = $Description -match 'AB#\d+'
    if (-not $HasWorkItemText) {
        throw "Pull request description does not contain Azure Boards work item text (AB#<digits>)."
    }
    $HasWorkItemLink = $Description -match '\[AB#\d+\]\(.*\/_workitems\/edit\/\d+\/?\)'
    if ($HasWorkItemLink) {
        Write-Host "Pull request description contains a valid Azure Boards work item link after retry."
        return
    }
    else {
        throw "Pull request description still does not contain a valid Azure Boards work item link after retry."

    }
}
