# api-use-cases
Practical examples for using the StepSecurity API to answer real supply chain security questions.

## Scenarios

This repository includes workflows that demonstrate how to use the StepSecurity API to solve real-world supply chain security challenges:

### 1. Check Baseline Endpoints
**Workflow:** `.github/workflows/check-baseline-endpoints.yml`

Identifies which repositories in an organization are using specific network endpoints. This is useful for:
- Discovering dependencies on particular package registries (npm, PyPI, etc.)
- Finding repos using specific CDNs or external services
- Migration planning when moving to alternative endpoints (e.g., from npm to bun.sh)
- Inventory management of external dependencies

### 2. Token Permissions Impact Analysis
**Workflow:** `.github/workflows/token-permissions-impact-analysis.yml`

Analyzes the impact of restricting GitHub Actions token permissions across an organization. This helps answer:
- How many workflows lack explicit token permissions?
- Which jobs would be affected by changing the default from `write` to `read` permissions?
- What are the minimal required permissions for each job?
- How to implement least-privilege access without breaking workflows

### 3. Extract GitHub API Calls from Workflow Run
**Workflow:** `.github/workflows/extract-github-api-calls.yml`

Extracts all GitHub API calls (`api.github.com`) made by jobs in a specific workflow run. This is useful for:
- Auditing which GitHub API endpoints are called during CI/CD
- Detecting unexpected API calls (e.g., writing to repos outside the organization)
- Understanding the API footprint of GitHub Actions workflows
- Identifying API calls flagged with security detections (e.g., "Write to different Owner")

The workflow produces one CSV per job containing the step name, tool, HTTP method, API path, timestamp, and any associated detection info.

### 4. Harden Runner Compliance Report
**Workflow:** `.github/workflows/harden-runner-compliance.yml`

Generates a CSV compliance report showing which workflow jobs across a GitHub organization are monitored by Harden Runner. This helps answer:
- Which jobs have Harden Runner enabled (passed) vs missing (failed)?
- Are there any archived repos still appearing in compliance checks?
- What is the overall Harden Runner adoption rate across the org?
- Which repos need attention to achieve full compliance?

The report covers both GitHub-hosted and self-hosted runner controls, marks archived repos, and provides a summary with per-repo failure counts.

All workflows output structured data that can be used for reporting, compliance tracking, and making informed security decisions.

### 5. Actions in Use Detailed CSV Report
**Workflow:** `.github/workflows/actions-list-csv-basic.yml`

Generates a detailed CSV report of all GitHub Actions in use across your organization(s), including security scores, repository lists, and outbound network calls. This helps answer:
- What actions are currently in use across my org?
- Which actions have the lowest security scores?
- How many repos are using each action, and which repos specifically?
- What outbound network endpoints do these actions call?
- Are actions well-maintained, with branch protection and security policies?

This script requires your tenant name. You can find this under the Admin Console URL: `app.stepsecurity.io/<TENANT_NAME>/admin-console`
