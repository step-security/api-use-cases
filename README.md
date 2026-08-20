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

Generates a CSV compliance report showing which workflow jobs across a tenant (or a single GitHub organization) are monitored by Harden Runner. (For a report on any other control — e.g. `JobsShouldUseSecureRegistry` — see scenario 8, the generic Control Compliance Report. For *how compliance changed over time*, see scenario 10, the Compliance Trend report — the report below is always a point-in-time snapshot of the current state.) This helps answer:
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

### 5. Harden Runner Coverage Report
**Workflow:** `.github/workflows/harden-runner-coverage.yml`

Where the compliance report (above) answers *"which jobs are configured with Harden Runner today?"*, the coverage report answers *"of all the workflow runs that actually executed in a given window, how many were monitored by Harden Runner?"* This is the metric you watch over time to track adoption — and the per-workflow breakdown tells you exactly where the unmonitored runs are coming from.

Provide a `tenant` to report across every org in the tenant, or an `org` to scope the report to a single organization. The date range defaults to the last 7 days (UTC) and can be overridden with `start_date` / `end_date`. This helps answer:
- What percentage of workflow runs in the last *N* days were monitored by Harden Runner?
- Is coverage trending up or down day over day? (the `trend` column is the day-over-day delta in coverage %)
- On the most recent day, which repos and workflows are driving the bulk of the unmonitored runs?
- Across a tenant, which orgs are lagging on adoption?

Two CSVs are produced in a single run:

1. **`harden_runner_coverage_daily.csv`** — one row per `<owner × date>`. The time-series view for dashboards and trend charts.
2. **`harden_runner_coverage_workflows.csv`** — one row per `<owner × repo × workflow>` for the day(s) that include a per-repo breakdown (typically the end date). The drill-down for "where are the unmonitored runs coming from?"

#### `harden_runner_coverage_daily.csv` — one row per `<owner × date>`

| owner        | date       | monitored_runs | unmonitored_runs | total_runs | coverage_percentage | trend  |
|--------------|------------|----------------|------------------|------------|---------------------|--------|
| example-org  | 2026-05-22 | 62             | 79               | 141        | 43.97               | 0      |
| example-org  | 2026-05-23 | 1290           | 739              | 2029       | 63.58               | 19.61  |
| example-org  | 2026-05-24 | 606            | 393              | 999        | 60.66               | -1.64  |
| example-org  | 2026-05-25 | 1429           | 491              | 1920       | 74.43               | 12.64  |

#### `harden_runner_coverage_workflows.csv` — one row per `<owner × repo × workflow>` on the breakdown day(s)

| owner        | date       | repo                  | workflow_path                              | workflow_name                  | monitored_runs | unmonitored_runs | total_runs | coverage_percentage |
|--------------|------------|-----------------------|--------------------------------------------|--------------------------------|----------------|------------------|------------|---------------------|
| example-org  | 2026-05-25 | frontend-web-app      | .github/workflows/ci.yml                   | CI                             | 12             | 0                | 12         | 100                 |
| example-org  | 2026-05-25 | api-gateway           | .github/workflows/release.yml              | Release                        | 0              | 4                | 4          |                     |
| example-org  | 2026-05-25 | ml-training           | .github/workflows/train.yml                | Train model                    | 3              | 2                | 5          | 60                  |
| example-org  | 2026-05-25 | docs-site             | .github/workflows/scorecards.yml           | Scorecard supply-chain security| 0              | 1                | 1          |                     |

**Filter idioms this unlocks:**
- **Biggest offenders right now:** sort `harden_runner_coverage_workflows.csv` by `unmonitored_runs` desc → the workflows producing the most unmonitored runs today.
- **Zero-coverage workflows:** `monitored_runs = 0 AND total_runs > 0` → workflows that have *never* been monitored in the window, ranked by run volume.
- **Trend reversal:** sort `harden_runner_coverage_daily.csv` by `trend` ascending → days where adoption slipped (useful for catching regressions after a rollout).
- **Tenant-wide laggards:** group `harden_runner_coverage_daily.csv` by `owner` on the end date → which org has the lowest coverage %.

### 6. Actions in Use Detailed CSV Report
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

### 7. Match Action IOCs in Workflow Runs
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

### 8. Control Compliance Report (Any Control)
**Workflow:** `.github/workflows/control-compliance.yml`

Generates a CSV compliance report for **any StepSecurity GitHub Actions control** across a tenant (or a single GitHub organization). Where the Harden Runner Compliance Report (scenario 4) is a specialized report for the two Harden Runner controls (with runner-type classification), this scenario works for every control — pass the control name(s) as an input and get a uniform report back.

Control names you can pass (comma-separated for multiple):

- `JobsShouldUseSecureRegistry` — jobs that pull packages directly from public registries instead of a secure registry
- `GithubTokenShouldHaveMinPermission` — workflows missing minimal token permissions
- `OIDCShouldBeUsed` — jobs using long-lived cloud credentials instead of OIDC
- `ActionsShouldBePinned` — actions not pinned to a full commit SHA
- `MaintainedGitHubActionsShouldBeUsed` — third-party actions with a StepSecurity-maintained alternative
- `DefaultBranchShouldBeProtected` — repos without default-branch protection
- `GitHubHostedRunnerShouldBeHardened` / `SelfHostedRunnerShouldBeHardened` — jobs not monitored by Harden Runner

This helps answer:
- Which jobs are still pulling dependencies directly from public registries (npm, PyPI, etc.) instead of the Secure Registry?
- What is the pass/fail/suppressed breakdown for any control, per org and per repo?
- Which repos need attention first? (per-repo failure summary in the run logs)
- How is compliance for a control trending — run it on a schedule and diff the CSVs.

**Inputs:**
- `control` — one or more control names, comma-separated (required)
- `tenant` (report across all orgs in the tenant) or `org` (scope to one org)
- `failed_only` — only include non-compliant entries (applied server-side, keeps large-org runs fast)
- `include_details` — adds an `additional_info` column carrying the control's structured detail as JSON (e.g. for `JobsShouldUseSecureRegistry`, the matched registry endpoints with the most recent runs that called each one)

The report is fetched **per repository**, so results are complete regardless of how many checks the org has in total. Row granularity depends on the control: most controls emit one row per `<repo × workflow × job>`, some are per-action or per-repo — the `workflow`/`job` columns are simply empty where they don't apply. The `reason` column always carries the human-readable finding.

**Example output** (`JobsShouldUseSecureRegistry` across an org; the full CSV also includes `job_labels`, `workflow_url`, `first_failed`, `last_failed`, `last_checked`):

| owner       | repo             | workflow      | job     | control                     | status | reason                                                          | job_url                                                                   |
|-------------|------------------|---------------|---------|-----------------------------|--------|------------------------------------------------------------------|----------------------------------------------------------------------------|
| example-org | frontend-web-app | ci.yml        | build   | JobsShouldUseSecureRegistry | Failed | Job calls public registries directly: registry.npmjs.org         | https://github.com/example-org/frontend-web-app/actions/runs/100/job/200  |
| example-org | ml-training      | train.yml     | train   | JobsShouldUseSecureRegistry | Failed | Job calls public registries directly: pypi.org, files.pythonhosted.org | https://github.com/example-org/ml-training/actions/runs/101/job/201  |
| example-org | api-gateway      | release.yml   | publish | JobsShouldUseSecureRegistry | Passed | No public registry calls found in the job's network baseline     | https://github.com/example-org/api-gateway/actions/runs/102/job/202       |

The run summary at the bottom of the workflow log gives per-control and per-org breakdowns:

```
=== COMPLIANCE SUMMARY for organization 'example-org' ===
Controls:          JobsShouldUseSecureRegistry
Total orgs:        1
Total repos:       42
Total checks:      118
  Passed:          97
  Failed:          19
  Suppressed:      2

Per-control breakdown:
  JobsShouldUseSecureRegistry: total=118, passed=97, failed=19, suppressed=2

Repos with non-compliant checks (7):
  example-org/frontend-web-app: 6 failing check(s)
  example-org/ml-training: 4 failing check(s)
```

### 9. Export Access Control (Roles, Permissions & Entitlements)
**Workflow:** `.github/workflows/export-access-control.yml`

Exports your tenant's complete access-control model as **two CSVs** in a single run, so you can review it in a spreadsheet, hand it to an auditor, or feed it into another system. It covers the two built-in roles (`admin`, `auditor`) plus every custom role your tenant has defined, and maps every user to the roles they hold. This helps answer:

- What can each role do? (the exact permission list behind `admin`, `auditor`, and each custom role)
- Who has access, and at what role? (every user and the role(s) granted to them)
- At what scope is each grant applied — the whole tenant, a single organization, or specific repositories/projects?
- Which users hold the most privileged (`admin`) access?
- Which custom roles exist, who created them, and what do they grant?

This script requires your tenant name. You can find it under the Admin Console URL: `app.stepsecurity.io/<TENANT_NAME>/admin-console`

Two CSVs are produced:

1. **`roles_permissions.csv`** — one row per `<role × permission>`. The "what can each role do?" view.
2. **`role_entitlements.csv`** — one row per `<user × role grant>`. The "who has access to what?" view.

#### `roles_permissions.csv` — one row per role × permission

`role_type` is `built-in` for the two system roles and `custom` for tenant-defined roles. `role_id` and `description` are populated only for custom roles.

| role      | role_type | role_id                              | description               | permission             |
|-----------|-----------|--------------------------------------|---------------------------|------------------------|
| admin     | built-in  |                                      |                           | baseline-write         |
| admin     | built-in  |                                      |                           | detections-write       |
| auditor   | built-in  |                                      |                           | baseline-read          |
| auditor   | built-in  |                                      |                           | detections-read        |
| developer | custom    | bd2f8264-dedd-4471-b59c-ff1bab4ed6e6 | Gives access to developers | workflow-runs-read     |
| developer | custom    | bd2f8264-dedd-4471-b59c-ff1bab4ed6e6 | Gives access to developers | baseline-read          |

#### `role_entitlements.csv` — one row per user × role grant

`scope` is the breadth of the grant (`customer` = whole tenant, `organization`, or `repository`). `organization` and `scope_targets` are normalized across GitHub, GitLab, and Azure DevOps; `*` means "all". A user with no grants is still listed once with empty role columns so nobody is silently dropped.

| user             | auth_type | role    | scope        | platform | organization    | scope_targets |
|------------------|-----------|---------|--------------|----------|-----------------|---------------|
| alice-example    | Github    | admin   | customer     | github   | *               | *             |
| bob-example      | Github    | auditor | organization | github   | example-org     | *             |
| carol@example.io | Local     | admin   | customer     | *        | *               | *             |
| dave-example     | Github    | developer | repository | github   | example-org     | frontend-web-app\|api-gateway |

**Filter idioms this unlocks:**
- **Privileged-access review:** filter `role_entitlements.csv` on `role = "admin"` → everyone with full access, the first list any auditor asks for.
- **Least-privilege check on a role:** filter `roles_permissions.csv` on a `role` and look for `-write` permissions → does this role grant more than it should?
- **Custom-role inventory:** filter `roles_permissions.csv` on `role_type = "custom"` → every tenant-defined role and exactly what it grants.
- **Scoped vs. tenant-wide access:** filter `role_entitlements.csv` on `scope != "customer"` → grants limited to specific orgs or repos, useful for spotting where access is (or isn't) narrowed.

### 10. Harden Runner Compliance Trend
**Workflow:** `.github/workflows/harden-runner-compliance-trend.yml`

Answers *"how many more repos became compliant with Harden Runner over the last N days?"* The compliance report (scenario 4) is point-in-time: the controls API always returns the current state and does not accept date filters, so it cannot answer trend questions on its own. This report instead uses the Harden Runner coverage API, which stores roughly one year of daily history of monitored vs unmonitored runs per repository, and compares two windows: a baseline window ending `days_ago` days ago (default 30) and a current window ending yesterday (both `window` days wide, default 7). This helps answer:
- How many repos became fully monitored (compliant) since the baseline?
- Did any repos regress from fully monitored to partially or unmonitored?
- Which repos are new since the baseline, and did they start out compliant?
- Is org-wide run coverage trending up or down between the two windows?

A repo only appears in a day's coverage data if it ran workflows that day, which is why each side aggregates a multi-day window instead of comparing two single days. Repos with no runs in a window are classified `no_runs` / `no_recent_runs` rather than guessed at.

**Example output** (`harden_runner_trend.csv` — one row per repo):

| repo             | transition          | baseline_status     | baseline_monitored_runs | baseline_total_runs | current_status      | current_monitored_runs | current_total_runs |
|------------------|---------------------|---------------------|-------------------------|---------------------|---------------------|------------------------|--------------------|
| frontend-web-app | became_compliant    | unmonitored         | 0                       | 14                  | fully_monitored     | 22                     | 22                 |
| api-gateway      | regressed           | fully_monitored     | 31                      | 31                  | partially_monitored | 12                     | 19                 |
| ml-training      | stayed_compliant    | fully_monitored     | 8                       | 8                   | fully_monitored     | 11                     | 11                 |
| docs-site        | still_noncompliant  | partially_monitored | 3                       | 9                   | unmonitored         | 0                      | 6                  |
| new-service      | new_repo_compliant  | no_runs             | 0                       | 0                   | fully_monitored     | 4                      | 4                  |

The run log also prints a summary: run coverage % for both windows, a count per transition type, and the lists of repos that became compliant or regressed.

**Filter idioms this unlocks:**
- **The headline number:** count rows with `transition = "became_compliant"` → "N more repos became compliant in the last 30 days."
- **Regression watchlist:** `transition = "regressed"` → repos that lost coverage since the baseline; investigate before the number grows.
- **Onboarding quality:** `transition = "new_repo_noncompliant"` → new repos that started life without Harden Runner, a signal to fix repo templates.
- **True time series:** for longer-term charts, run scenario 4 (or this report) on a schedule and archive the CSVs; each run is a durable snapshot.

### 11. Composite Actions Expansion
**Workflow:** `.github/workflows/list-composite-actions.yml`

Identifies which of the actions in use across an org are **composite actions**, and recursively expands the actions nested inside each one (the `uses:` steps in the composite's `action.yml`) until only leaf node/docker actions remain. A composite action can quietly pull in a whole tree of other actions, so the action you approved is rarely the only code that runs. This report makes that hidden dependency tree explicit. It helps answer:
- Which of the actions we depend on are composite actions rather than plain node/docker actions?
- What actions does each composite pull in, directly and transitively?
- How deep does a given composite's dependency tree go, and does a nested action reintroduce something we thought we had removed?
- After a compromised-action advisory, is the affected action reachable *inside* a composite we use, not just referenced directly?

It uses two public StepSecurity API endpoints: `GET /v1/github/<org>/actions/workflow-actions` for the inventory, then `POST /v1/github/actions/action-details` per action, which returns `actionType` (composite, node24, docker, and so on) and, for composites, the nested `composite_actions.actions` list. The script re-runs the details call on each nested action, memoizes results, and stops on cycles. Pass `--no-recurse` (or set the `no_recurse` input) to list only the direct children.

**Example output** (`composite_actions_tree.txt`, indented tree, one root per composite that calls other actions):

```
- aquasecurity/trivy-action [composite]
  - aquasecurity/setup-trivy@81e5143... [composite]
    - actions/cache/restore@9255dc7... [node24]
    - actions/checkout@8e8c483... [node24]
    - actions/cache/save@9255dc7... [node24]
  - actions/cache@55cc834... [node24]

- example-org/build-and-sign [composite]
  - actions/setup-go@b7ad1da... [node24]
  - example-org/internal-signer@a8f4274... [composite]
    - actions/upload-artifact@ea165f8... [node24]
```

The companion `composite_actions.csv` is the same data flattened for sorting and filtering:

| root_composite            | depth | action                                   | action_type | parent                     |
|---------------------------|-------|------------------------------------------|-------------|----------------------------|
| aquasecurity/trivy-action | 0     | aquasecurity/trivy-action                | composite   |                            |
| aquasecurity/trivy-action | 1     | aquasecurity/setup-trivy@81e5143...      | composite   | aquasecurity/trivy-action  |
| aquasecurity/trivy-action | 2     | actions/checkout@8e8c483...              | node24      | aquasecurity/setup-trivy   |
| aquasecurity/trivy-action | 1     | actions/cache@55cc834...                 | node24      | aquasecurity/trivy-action  |
| example-org/build-and-sign| 0     | example-org/build-and-sign               | composite   |                            |
| example-org/build-and-sign| 1     | example-org/internal-signer@a8f4274...   | composite   | example-org/build-and-sign |

**Filter idioms this unlocks:**
- **Composite inventory:** rows where `depth = 0` list every composite action in use.
- **Hidden dependencies:** rows where `depth >= 1` are actions that run only because a composite pulls them in, not because a workflow references them directly.
- **Deep trees:** sort by `depth` desc to find the composites with the longest transitive chains, the ones hardest to fully SHA-pin and audit.
- **Blast radius after an advisory:** filter `action` on the affected action name to see every composite whose tree includes it, then cross-reference with scenario 7 (Match Action IOCs) for runtime evidence.

### 12. Detect Deleted Workflow Runs
**Workflow:** `.github/workflows/detect-deleted-workflow-runs.yml`

Snapshots workflow-run metadata from the StepSecurity API and diffs it against the GitHub Actions API to find runs that **no longer exist on GitHub**.

StepSecurity records run metadata independently of GitHub. Deleting a workflow run is a common way to remove evidence after a secret-exfiltration attempt, and GitHub keeps no tenant-visible record that a run was ever deleted. Any run StepSecurity recorded that GitHub now returns 404 for is a lead worth investigating.

This helps answer:
- Did anyone delete workflow runs in the incident window, and which ones?
- Who triggered the deleted run, on what branch, from which workflow file?
- If nothing was deleted, where should the investigation go next?

Scope the analysis by time range, by run-id range, or both:

```bash
# Time range (dates or Unix epoch seconds)
./scripts/detect_deleted_workflow_runs.sh \
  --owner example-org --repo example-repo \
  --token "$STEPSECURITY_TOKEN" --github-token "$GH_TOKEN" \
  --start-time 2026-07-01 --end-time 2026-08-05

# Run-id range
./scripts/detect_deleted_workflow_runs.sh \
  --owner example-org --repo example-repo \
  --token "$STEPSECURITY_TOKEN" --github-token "$GH_TOKEN" \
  --min-run-id 30591205847 --max-run-id 31455880847

# Public repo: no GitHub token needed (anonymous, small scopes only)
./scripts/detect_deleted_workflow_runs.sh \
  --owner example-org --repo example-repo \
  --token "$STEPSECURITY_TOKEN" \
  --min-run-id 30591205847 --max-run-id 30591300000

# Snapshot StepSecurity metadata only, no GitHub diff
./scripts/detect_deleted_workflow_runs.sh \
  --owner example-org --repo example-repo \
  --token "$STEPSECURITY_TOKEN" --skip-github-check
```

**Output** (`deleted-run-analysis/`):
- `workflow-runs.json`: every run in scope, with metadata plus a `github_state` field
- `deleted-runs.json`: only the runs GitHub no longer has
- `summary.json`: counts per state

**Example** `deleted-runs.json` entry:

| field | value |
|---|---|
| `run_id` | `31892041773` |
| `workflow_path` | `.github/workflows/codeql-analysis.yml` |
| `head_branch` | `fix/ci-retry` |
| `event` | `push` |
| `actor` | `example-user` |
| `started_at` | `2026-08-02T03:14:52Z` |
| `secrets_detected_count` | `1` |
| `github_state` | `deleted` |
| `stepsecurity_url` | `https://app.stepsecurity.io/github/example-org/example-repo/actions/runs/31892041773` |

Each run is classified so an access problem can never be mistaken for an attack:

| `github_state` | Meaning |
|---|---|
| `present` | Run still exists on GitHub (HTTP 200) |
| `deleted` | Run is gone (HTTP 404). Investigate |
| `inaccessible` | HTTP 401/403, a token problem. **Not** counted as deleted |
| `rate_limited` | HTTP 429. Re-run with a lower `--parallel` |
| `unknown` | Any other response. Not counted as deleted |

**Interpreting the result:**
- **Runs were deleted** → start with those. Cross-reference the `head_branch` and `actor`, and pull the branch's workflow file at that commit to see what the run actually did.
- **Nothing was deleted** → no evidence was removed, so review the workflow files themselves. Search every branch (not just the default) for `toJSON(secrets)`, which serializes every secret in scope, and for dynamic indexing such as `secrets[<expression>]`, which static analysis cannot bound to a single secret.

**GitHub credentials:** `--github-token` is optional.

| Situation | What to use | Rate limit |
|---|---|---|
| Public target repo | Nothing, or the workflow's `GITHUB_TOKEN` | 60/hour anonymous, 5,000/hour with `GITHUB_TOKEN` |
| Private target repo | `GH_READ_TOKEN` secret: a PAT with `actions: read` | 5,000/hour |

The workflow prefers `GH_READ_TOKEN`, falls back to `GITHUB_TOKEN`, and only skips the diff if you explicitly ask it to. A public repo therefore needs no extra setup.

**Requirements and limits worth knowing before you run it:**
- The StepSecurity runs listing **rejects a `start_time` more than 90 days in the past**, so this cannot look further back than 90 days. The script defaults to just inside that limit and clamps a too-old `start_time` forward rather than failing partway through pagination.
- The API has no run-id filter, so a run-id range is applied client-side after fetching the window. A run-id range on its own uses the default 90-day window.
- This spends **one GitHub API request per run**, so anonymous access realistically covers fewer than 60 runs. The script reads your actual remaining quota before checking anything and stops with the reset time if it is insufficient, rather than half-completing and reporting the result as if it were whole.
- For a **private** repo, GitHub returns **404 rather than 403** when a token lacks `actions: read`, which would make every run look deleted. The script verifies repo and Actions-listing access up front, refuses to run on an underscoped token, and warns if literally every run comes back 404.
- `summary.json` always carries the same keys, and `github_checked` tells you whether the GitHub diff actually ran. Treat `deleted_from_github: 0` as meaningful **only** when `github_checked` is `true`, otherwise nothing was looked at.
