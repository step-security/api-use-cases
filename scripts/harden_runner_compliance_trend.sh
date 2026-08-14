#!/usr/bin/env bash
#
# harden_runner_compliance_trend.sh
#
# Answers "how many repos became compliant with harden-runner over the
# last N days?" by comparing two windows of Harden-Runner coverage
# data: a baseline window (ending N days ago) and a current window
# (ending yesterday).
#
# Why this script exists: the controls API
# (/github/{org}/{repo}/actions/controls/{control}) is point-in-time.
# It always returns the CURRENT compliance state and does not accept
# date filters, so it cannot answer trend questions. The Harden-Runner
# coverage API, however, stores roughly one year of daily history of
# monitored vs unmonitored workflow runs per repository. A repo whose
# runs are all monitored is what the harden-runner compliance controls
# measure, so comparing coverage windows gives a faithful compliance
# trend.
#
# A repo appears in a day's data only if it ran workflows that day, so
# single-day comparisons are sparse. This script aggregates a multi-day
# window on each side (default 7 days) and classifies each repo:
#   fully_monitored     all runs in the window used harden-runner
#   partially_monitored some runs used harden-runner
#   unmonitored         no runs used harden-runner
#
# Usage:
#   ./harden_runner_compliance_trend.sh --org <github-org> --token <stepsecurity-token> [--days-ago <n>] [--window <days>] [--output <file.csv>]
#
# Requirements: curl, jq

set -euo pipefail

BASE_URL="https://agent.api.stepsecurity.io/v1"
ORG=""
TOKEN=""
DAYS_AGO=30
WINDOW=7
OUTPUT="harden_runner_trend.csv"

usage() {
  echo "Usage: $0 --org <org> --token <stepsecurity-token> [--days-ago <n>] [--window <days>] [--output <file>]"
  echo ""
  echo "  --org        GitHub organization name"
  echo "  --token      StepSecurity API bearer token"
  echo "  --days-ago   How far back the baseline window ends (default: 30)"
  echo "  --window     Days aggregated per window (default: 7)"
  echo "  --output     Output CSV file (default: harden_runner_trend.csv)"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --org)      ORG="$2"; shift 2 ;;
    --token)    TOKEN="$2"; shift 2 ;;
    --days-ago) DAYS_AGO="$2"; shift 2 ;;
    --window)   WINDOW="$2"; shift 2 ;;
    --output)   OUTPUT="$2"; shift 2 ;;
    *)          usage ;;
  esac
done

if [[ -z "$ORG" || -z "$TOKEN" ]]; then
  usage
fi

if [[ "$WINDOW" -lt 1 || "$DAYS_AGO" -le "$WINDOW" ]]; then
  echo "Error: --days-ago (${DAYS_AGO}) must be greater than --window (${WINDOW})." >&2
  exit 1
fi

# ── 1. Set up working directory ────────────────────────────────────

TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT

# Portable date arithmetic (GNU on Linux, BSD on macOS)
days_ago_date() {
  if date -u -d "1970-01-01" +%Y-%m-%d >/dev/null 2>&1; then
    date -u -d "$1 days ago" +%Y-%m-%d
  else
    date -u -v-"$1"d +%Y-%m-%d
  fi
}

# ── 2. Fetch daily per-repo coverage for both windows ──────────────
#
# The org-level coverage endpoint returns per-repo detail only for the
# END date of the requested range, so we call it once per day with
# start_date == end_date and aggregate locally.

fetch_window() {
  local label="$1" first_offset="$2" outdir="$3"
  mkdir -p "$outdir"
  local fetched=0
  for ((i = 0; i < WINDOW; i++)); do
    local offset=$((first_offset + i))
    local day
    day=$(days_ago_date "$offset")

    local response http_code
    response=$(curl -s -w "\n%{http_code}" \
      -H "Authorization: $TOKEN" \
      "${BASE_URL}/github/${ORG}/actions/harden-runner-coverage?start_date=${day}&end_date=${day}")
    http_code=$(echo "$response" | tail -1)

    if [[ "$http_code" -ne 200 ]]; then
      echo "  [${label}] ${day}: HTTP ${http_code}, skipping day" >&2
      continue
    fi

    # Keep only that day's per-repo map
    echo "$response" | sed '$d' | jq --arg d "$day" '.[$d].repositories // {}' \
      > "${outdir}/${day}.json"
    local repo_count
    repo_count=$(jq 'length' "${outdir}/${day}.json")
    echo "  [${label}] ${day}: ${repo_count} repos with runs"
    fetched=$((fetched + 1))
  done

  if [[ "$fetched" -eq 0 ]]; then
    echo "Error: no coverage data retrieved for the ${label} window." >&2
    exit 1
  fi
}

CURRENT_END=$(days_ago_date 1)
CURRENT_START=$(days_ago_date "$WINDOW")
BASELINE_END=$(days_ago_date "$DAYS_AGO")
BASELINE_START=$(days_ago_date $((DAYS_AGO + WINDOW - 1)))

echo "Baseline window: ${BASELINE_START} to ${BASELINE_END}"
echo "Current window:  ${CURRENT_START} to ${CURRENT_END}"
echo ""
echo "Fetching daily coverage for '${ORG}'..."

fetch_window "baseline" "$DAYS_AGO" "$TMPDIR_WORK/baseline"
fetch_window "current" 1 "$TMPDIR_WORK/current"

# ── 3. Aggregate each window per repo ───────────────────────────────

aggregate_window() {
  local dir="$1" out="$2"
  jq -s '
    map(to_entries) | flatten
    | group_by(.key)
    | map({
        repo: .[0].key,
        monitored: (map(.value.monitored_runs) | add),
        total: (map(.value.total_runs) | add)
      })
    | map(. + {
        status: (
          if .total == 0 then "inactive"
          elif .monitored == .total then "fully_monitored"
          elif .monitored == 0 then "unmonitored"
          else "partially_monitored"
          end
        )
      })
  ' "$dir"/*.json > "$out"
}

aggregate_window "$TMPDIR_WORK/baseline" "$TMPDIR_WORK/baseline.json"
aggregate_window "$TMPDIR_WORK/current" "$TMPDIR_WORK/current.json"

# ── 4. Join windows and classify transitions ───────────────────────

RESULT="$TMPDIR_WORK/result.json"

jq -n \
  --slurpfile base "$TMPDIR_WORK/baseline.json" \
  --slurpfile cur "$TMPDIR_WORK/current.json" '
  ($base[0] | map({key: .repo, value: .}) | from_entries) as $b
  | ($cur[0] | map({key: .repo, value: .}) | from_entries) as $c
  | (($b | keys) + ($c | keys) | unique) as $repos
  | [ $repos[] | . as $r
      | ($b[$r] // null) as $bv
      | ($c[$r] // null) as $cv
      | {
          repo: $r,
          baseline_status: ($bv.status // "no_runs"),
          baseline_monitored: ($bv.monitored // 0),
          baseline_total: ($bv.total // 0),
          current_status: ($cv.status // "no_runs"),
          current_monitored: ($cv.monitored // 0),
          current_total: ($cv.total // 0),
          transition: (
            if $bv == null and $cv == null then "no_data"
            elif $bv == null then
              (if $cv.status == "fully_monitored" then "new_repo_compliant" else "new_repo_noncompliant" end)
            elif $cv == null then "no_recent_runs"
            elif $bv.status != "fully_monitored" and $cv.status == "fully_monitored" then "became_compliant"
            elif $bv.status == "fully_monitored" and $cv.status != "fully_monitored" then "regressed"
            elif $cv.status == "fully_monitored" then "stayed_compliant"
            else "still_noncompliant"
            end
          )
        }
    ]
  | sort_by(.transition, .repo)
' > "$RESULT"

# ── 5. Write CSV ────────────────────────────────────────────────────

echo "repo,transition,baseline_status,baseline_monitored_runs,baseline_total_runs,current_status,current_monitored_runs,current_total_runs" > "$OUTPUT"
jq -r '
  .[]
  | [.repo, .transition, .baseline_status, .baseline_monitored, .baseline_total, .current_status, .current_monitored, .current_total]
  | @csv
' "$RESULT" >> "$OUTPUT"

echo ""
echo "Wrote $(jq 'length' "$RESULT") repos to $OUTPUT"

# ── 6. Summary ──────────────────────────────────────────────────────

summarize_window() {
  jq -r '
    (map(.monitored) | add // 0) as $m
    | (map(.total) | add // 0) as $t
    | ([.[] | select(.status == "fully_monitored")] | length) as $full
    | "runs monitored: \($m)/\($t) (\(if $t > 0 then ($m / $t * 10000 | round) / 100 else 0 end)%), repos active: \(length), fully monitored: \($full)"
  ' "$1"
}

echo ""
echo "=== HARDEN-RUNNER COMPLIANCE TREND for '${ORG}' ==="
echo "Baseline (${BASELINE_START} to ${BASELINE_END}): $(summarize_window "$TMPDIR_WORK/baseline.json")"
echo "Current  (${CURRENT_START} to ${CURRENT_END}): $(summarize_window "$TMPDIR_WORK/current.json")"
echo ""

for T in became_compliant regressed new_repo_compliant new_repo_noncompliant stayed_compliant still_noncompliant no_recent_runs; do
  COUNT=$(jq --arg t "$T" '[.[] | select(.transition == $t)] | length' "$RESULT")
  echo "${T}: ${COUNT}"
done

echo ""
echo "Repos that became compliant:"
jq -r '.[] | select(.transition == "became_compliant") | "  " + .repo' "$RESULT"
echo ""
echo "Repos that regressed:"
jq -r '.[] | select(.transition == "regressed") | "  " + .repo' "$RESULT"
