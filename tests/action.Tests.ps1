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
        } | Should -Throw '*markdown link*/*_workitems/edit/*'
    }
}
