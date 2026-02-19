#!/bin/bash

# Check if all required arguments are provided
if [ $# -ne 4 ]; then
    echo "Usage: $0 <owner> <repo> <run_id> <api_key>"
    echo "Example: $0 'actions-security-demo' 'microservice-ghcr' '21918052283' 'step_abc123...'"
    exit 1
fi

# Configuration variables from command line arguments
OWNER="$1"
REPO="$2"
RUN_ID="$3"
API_KEY="$4"
BASE_URL="https://agent.api.stepsecurity.io/v1/github"
OUTPUT_DIR="github-api-calls"

mkdir -p "$OUTPUT_DIR"

echo "Fetching workflow run details for $OWNER/$REPO run $RUN_ID"
echo "----------------------------------------"

# Fetch the workflow run data
RESPONSE=$(curl -s -X 'GET' \
  "$BASE_URL/$OWNER/$REPO/actions/runs/$RUN_ID" \
  -H 'accept: application/json' \
  -H "Authorization: $API_KEY")

if [ $? -ne 0 ]; then
    echo "Error: Failed to fetch workflow run details"
    exit 1
fi

# Validate response contains jobs
JOB_COUNT=$(echo "$RESPONSE" | jq '.jobs | length')
if [ "$JOB_COUNT" -eq 0 ] || [ "$JOB_COUNT" = "null" ]; then
    echo "Error: No jobs found in the workflow run response"
    exit 1
fi

WORKFLOW_NAME=$(echo "$RESPONSE" | jq -r '.name // "unknown"')
echo "Workflow: $WORKFLOW_NAME"
echo "Jobs found: $JOB_COUNT"
echo "----------------------------------------"

TOTAL_API_CALLS=0

# Process each job
for i in $(seq 0 $((JOB_COUNT - 1))); do
    JOB_NAME=$(echo "$RESPONSE" | jq -r ".jobs[$i].name")
    JOB_ID=$(echo "$RESPONSE" | jq -r ".jobs[$i].id")

    # Sanitize job name for filename
    SAFE_NAME=$(echo "$JOB_NAME" | tr ' ' '-' | tr -cd '[:alnum:]-_')
    CSV_FILE="$OUTPUT_DIR/${SAFE_NAME}-${JOB_ID}.csv"

    echo "Processing job: $JOB_NAME (ID: $JOB_ID)"

    # Extract GitHub API calls (to api.github.com) from all steps and tools
    echo "$RESPONSE" | jq -r --argjson idx "$i" '
        .jobs[$idx] as $job |
        ["step_name","step_number","tool_name","method","path","timestamp","detection_id","detection_name"],
        (
            $job.steps[]? as $step |
            $step.tools[]? as $tool |
            $tool.https_endpoints[]? |
            select(.host == "api.github.com") |
            [
                $step.name,
                ($step.number | tostring),
                $tool.name,
                .method,
                .path,
                .timestamp,
                (.detection.id // ""),
                (.detection.name // "")
            ]
        ) | @csv
    ' > "$CSV_FILE"

    # Check if any API calls were found (more than just the header)
    LINE_COUNT=$(wc -l < "$CSV_FILE" | tr -d ' ')
    if [ "$LINE_COUNT" -le 1 ]; then
        echo "  No GitHub API calls found"
        rm "$CSV_FILE"
    else
        API_COUNT=$((LINE_COUNT - 1))
        TOTAL_API_CALLS=$((TOTAL_API_CALLS + API_COUNT))
        echo "  Found $API_COUNT GitHub API call(s) -> $CSV_FILE"
    fi
done

echo "----------------------------------------"
echo "Total GitHub API calls across all jobs: $TOTAL_API_CALLS"
echo "Results saved to $OUTPUT_DIR/"
