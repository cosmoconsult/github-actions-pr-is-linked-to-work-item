# Check for an Azure Boards link

Use this action to ensure the current pull request description includes a markdown link whose visible text is an Azure Boards work item such as `AB#123` and whose target URL contains `/_workitems/edit/`.

The action checks the current description first. If it contains an `AB#<ID>` reference but the link format is invalid, it waits 10 seconds, fetches the pull request again, and checks one more time. If no `AB#<ID>` reference is present, the action fails immediately without retrying.

## Usage

Add the action to a pull request workflow:

```yml
name: Check PR for Azure Boards link

on:
  pull_request:
    types:
      - opened
      - reopened
      - edited
      - synchronize
    branches:
      - main
permissions:
  pull-requests: read

jobs:
  check-link:
    runs-on: ubuntu-latest
    steps:
      - uses: cosmoconsult/github-actions-pr-is-linked-to-work-item@main
```

## Link Format

The action accepts links that look like this:

```md
[AB#123](https://dev.azure.com/contoso/project/_workitems/edit/123)
```

The visible text must match `AB#` followed by digits. The URL must contain `/_workitems/edit/`.

## Input

The action keeps the existing `repo-token` input. It defaults to `github.token`, so most workflows do not need to pass anything explicitly.
