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

Produces **two complementary CSVs** in a single run:

1. **`workflow_actions_detailed.csv`** — one row per unique action (the "is this action safe to approve?" view).
2. **`workflow_actions_usage.csv`** — one row per `<action × repo × workflow>` usage (the "where do I need to bump or pin?" view).

Together they cover security scores, repository lists, outbound network calls, **StepSecurity-maintained drop-in replacements**, pin type (SHA / tag / branch), version drift vs. the latest release, and last-execution recency. This helps answer:
- What actions are currently in use across my org?
- Which actions have the lowest security scores?
- **Is there a StepSecurity-maintained alternative I can swap in for a risky third-party action?** (`maintained_action_name` column)
- How many repos are using each action, and which repos specifically?
- What outbound network endpoints do these actions call?
- Are actions well-maintained, with branch protection and security policies?
- **Which usages are SHA-pinned vs. tag-only vs. branch-tracking?** (`pin_type` column)
- **Which usages are running an outdated version, and how far behind?** (`is_latest` / `days_behind_latest` columns)
- **Are dormant workflows still wired to risky actions?** (`last_executed_days_ago` column)
- **Which usages are inside a reusable workflow (so a fix has multiplier impact)?** (`reusable_workflow` column)

> 💡 **Maintained-action column:** the `maintained_action_name` column is populated whenever StepSecurity publishes a hardened, regularly updated equivalent of the action (e.g. `tj-actions/changed-files` → `step-security/changed-files`). An empty value means no StepSecurity-maintained alternative exists for that action today. Filtering the CSV on rows where this column is non-empty gives you an instant, prioritized migration list.

This script requires your tenant name. You can find this under the Admin Console URL: `app.stepsecurity.io/<TENANT_NAME>/admin-console`

#### `workflow_actions_detailed.csv` — one row per action

(Selected columns; the full CSV has 30+ columns including per-dimension score breakdowns and reasons.)

| owner        | action_name                    | workflow_count | repo_count | repositories                                  | overall_score | maintained_score | security_policy_score | vulnerabilities_score | maintained_action_name              | outbound_endpoints                                |
|--------------|--------------------------------|----------------|------------|-----------------------------------------------|---------------|------------------|------------------------|------------------------|--------------------------------------|---------------------------------------------------|
| example-org  | actions/checkout               | 87             | 42         | frontend-web-app, api-gateway, docs-site, ... | 9             | 10               | 10                     | 8                      |                                      | github.com (GitHub), api.github.com (GitHub API)  |
| example-org  | actions/setup-node             | 54             | 31         | frontend-web-app, internal-tooling, ...       | 9             | 10               | 10                     | 9                      |                                      | nodejs.org (Node.js Downloads)                    |
| example-org  | tj-actions/changed-files       | 18             | 11         | api-gateway, frontend-web-app, ...            | 7             | 6                | 5                      | 7                      | **step-security/changed-files**      | api.github.com (GitHub API)                       |
| example-org  | some-vendor/legacy-deploy      | 6              | 3          | legacy-svc, internal-tooling, infra-tests     | 3             | 2                | 0                      | 4                      |                                      | deploy.example.vendor.com                         |
| example-org  | docker/build-push-action       | 22             | 14         | api-gateway, ml-training, infra-tests, ...    | 8             | 9                | 8                      | 8                      |                                      | registry-1.docker.io, ghcr.io                     |

#### `workflow_actions_usage.csv` — one row per `<action × repo × workflow>` usage

This CSV is what you sort and filter to drive cleanup. It exposes pin type, version drift, and last-execution recency — none of which appear in the per-action CSV. Real-world signal from a single org of ~180 actions: ~1,300 usage rows, ~44% SHA-pinned vs. ~56% tag-only, ~93% running a non-latest version. The `days_behind_latest` column lets you sort the riskiest usages first.

(Selected columns; the full CSV also includes `branch`, `pinned_sha`, `version_release_date`, `latest_release_date`, `last_run_id`, and `workflow_url`.)

| owner       | action_name                | repo              | workflow                              | pin_type | pinned_tag | is_latest | latest_version | days_behind_latest | last_executed | last_executed_days_ago | runner_labels             | reusable_workflow                              |
|-------------|----------------------------|-------------------|---------------------------------------|----------|------------|-----------|----------------|---------------------|---------------|--------------------------|---------------------------|------------------------------------------------|
| example-org | actions/checkout           | api-gateway       | .github/workflows/codeql.yml          | sha      | v4.3.1     | false     | v6.0.2         | 56                  | 2026-04-21    | 5                        | ubuntu-latest             |                                                |
| example-org | actions/checkout           | frontend-web-app  | .github/workflows/release.yml         | tag      | v6         | true      | v6.0.2         | 0                   | 2026-04-23    | 3                        | ubuntu-latest             |                                                |
| example-org | actions/checkout           | docs-site         | .github/workflows/audit_package.yml   | sha      | v4.2.2     | false     | v6.0.2         | 444                 | 2026-04-22    | 4                        | ubuntu-latest             | .github/workflows/audit_fix.yml                |
| example-org | tj-actions/changed-files   | infra-tests       | .github/workflows/lint.yml            | tag      | v44        | false     | v50            | 559                 | 2026-04-15    | 11                       | ubuntu-latest             |                                                |
| example-org | some-vendor/legacy-deploy  | legacy-svc        | .github/workflows/deploy.yml          | branch   |            | false     | v3             |                     | 2026-03-14    | 43                       | self-hosted, linux        | .github/workflows/legacy-pipeline.yml          |
| example-org | docker/build-push-action   | ml-training       | .github/workflows/build.yml           | sha      | v6.7.0     | true      | v6.7.0         | 0                   | 2026-04-25    | 1                        | self-hosted, linux, gpu   |                                                |

**Filter idioms this unlocks:**
- **SHA-pinning audit:** `pin_type != "sha"` → every place not commit-pinned.
- **Migration backlog:** `is_latest = false` sorted by `days_behind_latest` desc → biggest version drift first.
- **Dormant + risky combo:** `last_executed_days_ago > 90 AND <action on a known-risky list>` → workflows still wired to risky actions but rarely running.
- **Reusable-workflow blast radius:** filter `reusable_workflow != ""` and group by it → single fixes that unblock many callers.
- **Cross-reference with maintained alternatives:** join on `action_name` against `workflow_actions_detailed.csv` rows where `maintained_action_name` is non-empty → a concrete usage list to migrate to StepSecurity-maintained replacements.

### 6. Match Action IOCs in Workflow Runs
**Workflow:** `.github/workflows/match-action-iocs.yml`

When a supply chain incident publishes a list of compromised `<action, commit-SHA>` pairs, you need to know **which workflow runs in your tenant actually executed those compromised commits** — not just which repos *list* the action in YAML, but which runs actually pulled and ran that exact SHA. This scenario answers that.

It scans every workflow run in a configurable time window (max 90 days, the StepSecurity API limit), pulls the runtime `actions_info` for each run, and matches the executed commit SHAs against your IOC list.

This helps answer:
- **Did any run in the last N days actually execute a compromised commit SHA?**
- **Which repos, workflows, runs, and jobs are affected?**
- **Was the run on the default branch, and did it conclude successfully?** (so you know what credentials/artifacts may have been exposed)
- **Has StepSecurity already independently flagged it as an imposter commit?** (`is_imposter_commit` column — orthogonal signal you get for free)
- **Which IOC entry caused each match?** (the `label` from your IOC CSV is carried through — useful when you're scanning multiple incidents at once)

**Inputs:**
- `--tenant` (scan all orgs in the tenant) or `--org` (scope to one org)
- `--ioc-csv <path>` — CSV with header row `action,sha,label`. `sha` is required. `action` is optional (when present, both action AND sha must match; when blank, any usage of that SHA matches). `label` is free-form and is carried into the output.
- Time window: `--days N` shortcut, or explicit `--start-time <epoch>` / `--end-time <epoch>` (epoch seconds).

#### Example IOC CSV

| action                       | sha                                            | label                          |
|------------------------------|------------------------------------------------|--------------------------------|
| `tj-actions/changed-files`   | `0e58ed867288ce82bdcabd8c25aaaa0c4ee1c8b4`     | `CVE-2025-30066`               |
|                              | `abcdef0123456789abcdef0123456789abcdef01`     | `Shai-Hulud-Wave1`             |
| `some-vendor/legacy-deploy`  | `deadbeefdeadbeefdeadbeefdeadbeefdeadbeef`     | `Internal-Bulletin-2026-04-12` |

The middle row leaves `action` blank — any usage of that SHA matches, regardless of which action name was specified in the workflow.

#### Example output (`workflow_run_ioc_matches.csv`)

(Selected columns; the full CSV also includes `run_url`, `event`, `head_branch`, `committer`, `run_started_at`, `run_conclusion`, `job_url`, `matched_tag`, `action_executed_at`, `is_commit_on_default_branch`.)

| owner       | repo              | run_id      | run_attempt | workflow_path                       | job_name              | matched_action               | matched_sha                                | is_imposter_commit | ioc_label                |
|-------------|-------------------|-------------|-------------|--------------------------------------|-----------------------|-------------------------------|---------------------------------------------|---------------------|---------------------------|
| example-org | api-gateway       | 24971513660 | 1           | .github/workflows/release.yml       | publish               | tj-actions/changed-files      | 0e58ed867288ce82bdcabd8c25aaaa0c4ee1c8b4    | true                | CVE-2025-30066            |
| example-org | frontend-web-app  | 24970815039 | 2           | .github/workflows/ci.yml            | build                 | tj-actions/changed-files      | 0e58ed867288ce82bdcabd8c25aaaa0c4ee1c8b4    | true                | CVE-2025-30066            |
| example-org | infra-tests       | 24970721690 | 1           | .github/workflows/nightly.yml       | integration-tests     | some-vendor/legacy-deploy     | deadbeefdeadbeefdeadbeefdeadbeefdeadbeef    | false               | Internal-Bulletin-2026-04-12 |
| example-org | ml-training       | 24948693592 | 1           | .github/workflows/train.yml         | preprocess            | (any)                         | abcdef0123456789abcdef0123456789abcdef01    | false               | Shai-Hulud-Wave1          |

The run summary at the bottom of the workflow log gives a per-IOC breakdown so you can prioritize:

```
=== IOC MATCH SUMMARY for tenant 'example-tenant' (3 orgs) ===
Window:           2026-04-20T00:00:00Z → 2026-04-27T00:00:00Z
IOCs loaded:      3 (3 unique SHAs)
Total matches:    617
Unique runs:      316
Unique repos:     200

Per-IOC breakdown:
  CVE-2025-30066: 360 match(es) across 197 repo(s)
  Shai-Hulud-Wave1: 257 match(es) across 189 repo(s)
```
