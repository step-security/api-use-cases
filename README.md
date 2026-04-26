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

**Example output** (CSV — searching for `bun.sh:443` across an org):

| repo                | baseline_link                                                                                                       |
|---------------------|---------------------------------------------------------------------------------------------------------------------|
| frontend-web-app    | https://app.stepsecurity.io/github/example-org/actions/baseline?tab=repositories&repository=frontend-web-app        |
| internal-tooling    | https://app.stepsecurity.io/github/example-org/actions/baseline?tab=repositories&repository=internal-tooling        |
| docs-site           | https://app.stepsecurity.io/github/example-org/actions/baseline?tab=repositories&repository=docs-site               |

### 2. Token Permissions Impact Analysis
**Workflow:** `.github/workflows/token-permissions-impact-analysis.yml`

Analyzes the impact of restricting GitHub Actions token permissions across an organization. This helps answer:
- How many workflows lack explicit token permissions?
- Which jobs would be affected by changing the default from `write` to `read` permissions?
- What are the minimal required permissions for each job?
- How to implement least-privilege access without breaking workflows

**Example output** (selected fields from `impact-analysis.json`):

| repo               | workflow      | job        | baseline_permissions                       | would_be_impacted     |
|--------------------|---------------|------------|---------------------------------------------|------------------------|
| frontend-web-app   | ci.yml        | build      | `{"contents":"read"}`                       | No                     |
| internal-tooling   | release.yml   | publish    | `{"contents":"write","packages":"write"}`   | Yes                    |
| docs-site          | deploy.yml    | preview    | `{}` (no baseline data)                     | Potentially Impacted   |
| api-gateway        | lint.yml      | lint       | `{"contents":"read"}`                       | No                     |
| api-gateway        | release.yml   | tag        | `{"contents":"write"}`                      | Yes                    |

### 3. Extract GitHub API Calls from Workflow Run
**Workflow:** `.github/workflows/extract-github-api-calls.yml`

Extracts all GitHub API calls (`api.github.com`) made by jobs in a specific workflow run. This is useful for:
- Auditing which GitHub API endpoints are called during CI/CD
- Detecting unexpected API calls (e.g., writing to repos outside the organization)
- Understanding the API footprint of GitHub Actions workflows
- Identifying API calls flagged with security detections (e.g., "Write to different Owner")

The workflow produces one CSV per job containing the step name, tool, HTTP method, API path, timestamp, and any associated detection info.

**Example output** (one CSV per job, e.g. `release-publish-12345.csv`):

| step_name        | step_number | tool_name | method | host           | path                                | timestamp                |
|------------------|-------------|-----------|--------|----------------|-------------------------------------|--------------------------|
| Checkout         | 2           | git       | POST   | github.com     | /example-org/api-gateway.git/git-upload-pack | 2026-04-26T10:12:03.118Z |
| Create release   | 5           | gh        | POST   | api.github.com | /repos/example-org/api-gateway/releases | 2026-04-26T10:14:21.502Z |
| Upload asset     | 6           | curl      | POST   | api.github.com | /repos/example-org/api-gateway/releases/123/assets | 2026-04-26T10:14:34.811Z |
| Notify other org | 7           | curl      | POST   | api.github.com | /repos/other-org/notifications/issues | 2026-04-26T10:14:51.020Z |

### 4. Harden Runner Compliance Report
**Workflow:** `.github/workflows/harden-runner-compliance.yml`

Generates a CSV compliance report showing which workflow jobs across a tenant (or a single GitHub organization) are monitored by Harden Runner. This helps answer:
- Which jobs have Harden Runner enabled (passed) vs missing (failed)?
- Is the job running on a GitHub-hosted or self-hosted runner, and which runner labels does it use?
- What is the overall Harden Runner adoption rate across the tenant or org?
- Which repos need attention to achieve full compliance?

Provide a `tenant` to report across every org in the tenant, or an `org` to scope the report to a single organization. The CSV includes:
- An `owner` column so multi-org runs can be filtered per organization.
- A `runner_type` column that identifies each job as `GitHub-Hosted` or `Self-Hosted`.
- A `job_labels` column with the runner labels declared on the job (e.g. `ubuntu-latest`, or a self-hosted scale-set label like `dind-sidecar-eks-scaleset-arm`), which makes it easy to slice failures by runner pool.

The report covers both GitHub-hosted and self-hosted runner controls and provides a per-org and per-repo failure summary in the run logs.

**Example output** (selected columns; the full CSV also includes `workflow_url`, `first_failed`, `last_failed`, `last_checked`):

| owner        | repo             | workflow            | job              | control                                | runner_type   | status | job_labels                       | job_url                                                                                  |
|--------------|------------------|---------------------|------------------|----------------------------------------|---------------|--------|----------------------------------|------------------------------------------------------------------------------------------|
| example-org  | frontend-web-app | ci.yml              | build            | GitHubHostedRunnerShouldBeHardened     | GitHub-Hosted | Passed | ubuntu-latest                    | https://github.com/example-org/frontend-web-app/actions/runs/100/job/200                  |
| example-org  | api-gateway      | release.yml         | publish          | GitHubHostedRunnerShouldBeHardened     | GitHub-Hosted | Failed | ubuntu-latest                    | https://github.com/example-org/api-gateway/actions/runs/101/job/201                       |
| example-org  | ml-training      | train.yml           | train-model      | SelfHostedRunnerShouldBeHardened       | Self-Hosted   | Failed | self-hosted, linux, gpu          | https://github.com/example-org/ml-training/actions/runs/102/job/202                       |
| example-org  | infra-tests      | container-scenario.yml | test-docker   | SelfHostedRunnerShouldBeHardened       | Self-Hosted   | Failed | dind-sidecar-eks-scaleset-arm    | https://github.com/example-org/infra-tests/actions/runs/103/job/203                       |
| example-org  | docs-site        | deploy.yml          | preview          | GitHubHostedRunnerShouldBeHardened     | GitHub-Hosted | Suppressed | ubuntu-latest                | https://github.com/example-org/docs-site/actions/runs/104/job/204                         |

### 5. Actions in Use Detailed CSV Report
**Workflow:** `.github/workflows/actions-list-csv-basic.yml`

Generates a detailed CSV report of all GitHub Actions in use across your organization(s), including security scores, repository lists, outbound network calls, and — when available — a **StepSecurity-maintained drop-in replacement** for the action. This helps answer:
- What actions are currently in use across my org?
- Which actions have the lowest security scores?
- **Is there a StepSecurity-maintained alternative I can swap in for a risky third-party action?** (`maintained_action_name` column)
- How many repos are using each action, and which repos specifically?
- What outbound network endpoints do these actions call?
- Are actions well-maintained, with branch protection and security policies?

> 💡 **Maintained-action highlight:** the `maintained_action_name` column is populated whenever StepSecurity publishes a hardened, regularly updated equivalent of the action (e.g. `tj-actions/changed-files` → `step-security/changed-files`). An empty value means no StepSecurity-maintained alternative exists for that action today. Filtering the CSV on rows where this column is non-empty gives you an instant, prioritized migration list.

This script requires your tenant name. You can find this under the Admin Console URL: `app.stepsecurity.io/<TENANT_NAME>/admin-console`

**Example output** (selected columns; the full CSV has 30+ columns including per-dimension score breakdowns and reasons):

| owner        | action_name                    | workflow_count | repo_count | repositories                                  | overall_score | maintained_score | security_policy_score | vulnerabilities_score | maintained_action_name              | outbound_endpoints                                |
|--------------|--------------------------------|----------------|------------|-----------------------------------------------|---------------|------------------|------------------------|------------------------|--------------------------------------|---------------------------------------------------|
| example-org  | actions/checkout               | 87             | 42         | frontend-web-app, api-gateway, docs-site, ... | 9             | 10               | 10                     | 8                      |                                      | github.com (GitHub), api.github.com (GitHub API)  |
| example-org  | actions/setup-node             | 54             | 31         | frontend-web-app, internal-tooling, ...       | 9             | 10               | 10                     | 9                      |                                      | nodejs.org (Node.js Downloads)                    |
| example-org  | tj-actions/changed-files       | 18             | 11         | api-gateway, frontend-web-app, ...            | 7             | 6                | 5                      | 7                      | **step-security/changed-files**      | api.github.com (GitHub API)                       |
| example-org  | some-vendor/legacy-deploy      | 6              | 3          | legacy-svc, internal-tooling, infra-tests     | 3             | 2                | 0                      | 4                      |                                      | deploy.example.vendor.com                         |
| example-org  | docker/build-push-action       | 22             | 14         | api-gateway, ml-training, infra-tests, ...    | 8             | 9                | 8                      | 8                      |                                      | registry-1.docker.io, ghcr.io                     |

All workflows output structured data that can be used for reporting, compliance tracking, and making informed security decisions.
