Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    . "$PSScriptRoot/../action.ps1"
}

Describe 'Azure Boards link validation' {
    BeforeAll {
        $RepoToken = 'test-token'
    }

    It 'accepts Azure Boards work item text' {
        Test-WorkItemText -Description 'See [AB#123](https://dev.azure.com/org/project/_workitems/edit/123)' | Should -BeTrue
    }

    It 'rejects missing Azure Boards work item text' {
        Test-WorkItemText -Description 'No work item text here' | Should -BeFalse
    }

    It 'accepts a valid Azure Boards work item link' {
        Test-WorkItemLink -Description 'See [AB#123](https://dev.azure.com/org/project/_workitems/edit/123)' | Should -BeTrue
    }

    It 'accepts a valid Azure Boards work item link with a query string' {
        Test-WorkItemLink -Description 'See [AB#123](https://dev.azure.com/org/project/_workitems/edit/123?fullScreen=true)' | Should -BeTrue
    }

    It 'accepts a valid Azure Boards work item link with a fragment' {
        Test-WorkItemLink -Description 'See [AB#123](https://dev.azure.com/org/project/_workitems/edit/123#details)' | Should -BeTrue
    }

    It 'rejects a link that does not target Azure Boards work items' {
        Test-WorkItemLink -Description 'See [AB#123](https://example.com/123)' | Should -BeFalse
    }

    It 'rejects a link with extra path segments after the work item id' {
        Test-WorkItemLink -Description 'See [AB#123](https://dev.azure.com/org/project/_workitems/edit/123/extra)' | Should -BeFalse
    }

    It 'returns true for a valid description in Test-PullRequestDescription' {
        Mock Get-PullRequestDescriptionFromGitHub {
            'See [AB#123](https://dev.azure.com/org/project/_workitems/edit/123)'
        }

        $context = @{
            Owner = 'org'
            Repo = 'repo'
            PullRequestNumber = 1
        }

        Test-PullRequestDescription -PrContext $context | Should -BeTrue
        Should -Invoke Get-PullRequestDescriptionFromGitHub -Times 1
    }

    It 'returns false for AB text with invalid link in Test-PullRequestDescription' {
        Mock Get-PullRequestDescriptionFromGitHub {
            'See [AB#123](https://example.com/123)'
        }

        $context = @{
            Owner             = 'org'
            Repo              = 'repo'
            PullRequestNumber = 1
        }

        Test-PullRequestDescription -PrContext $context | Should -BeFalse
        Should -Invoke Get-PullRequestDescriptionFromGitHub -Times 1
    }

    It 'throws a clear error when AB text is missing in Test-PullRequestDescription' {
        Mock Get-PullRequestDescriptionFromGitHub {
            'No work item text here'
        }

        {
            Test-PullRequestDescription -PrContext (@{ Owner = 'org'; Repo = 'repo'; PullRequestNumber = 1 })
        } | Should -Throw '*AB#<digits>*'
    }
}
