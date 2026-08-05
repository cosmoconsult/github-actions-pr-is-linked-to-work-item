Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    . "$PSScriptRoot/../action.ps1"
}

Describe 'Azure Boards link validation' {
    It 'accepts a valid Azure Boards work item markdown link' {
        Test-WorkItemLinkDescription -Description 'See [AB#123](https://dev.azure.com/org/project/_workitems/edit/123)' | Should -BeTrue
    }

    It 'rejects a markdown link that does not target Azure Boards work items' {
        Test-WorkItemLinkDescription -Description 'See [AB#123](https://example.com/123)' | Should -BeFalse
    }

    It 'passes after a retry when the refreshed description is valid' {
        $validAfterRetry = { 'See [AB#123](https://dev.azure.com/org/project/_workitems/edit/123)' }.GetNewClosure()

        {
            Invoke-LinkCheck -InitialDescription 'No work item yet.' -RetryDelaySeconds 0 -DescriptionProvider $validAfterRetry
        } | Should -Not -Throw
    }

    It 'fails after one retry when the description is still invalid' {
        $stillInvalid = { 'Still missing the Azure Boards link.' }.GetNewClosure()

        {
            Invoke-LinkCheck -InitialDescription 'Still missing the Azure Boards link.' -RetryDelaySeconds 0 -DescriptionProvider $stillInvalid
        } | Should -Throw '*No markdown links were found*Expected format*'
    }

    It 'reports a clear reason for empty descriptions' {
        $result = Get-LinkValidationResult -Description ''

        $result.IsValid | Should -BeFalse
        $result.Reason | Should -Be 'Description is empty.'
    }

    It 'reports a clear reason when AB text exists but URL is wrong' {
        $result = Get-LinkValidationResult -Description 'See [AB#123](https://example.com/workitems/123)'

        $result.IsValid | Should -BeFalse
        $result.Reason | Should -Be 'Found markdown link text like AB#123, but the link target does not contain /_workitems/edit/.'
    }
}
