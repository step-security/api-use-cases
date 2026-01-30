#!/bin/bash

# Check if all required arguments are provided
if [ $# -ne 4 ]; then
    echo "Usage: $0 <owner> <api_key> <output_file> <destination_endpoint>"
    echo "Example: $0 'step-security' 'step_abc123...' 'results.csv' 'bun.sh:443'"
    exit 1
fi

# Configuration variables from command line arguments
OWNER="$1"
API_KEY="$2"
OUTPUT_FILE="$3"
DESTINATION_ENDPOINT="$4"
BASE_URL="https://agent.api.stepsecurity.io/v1/github"

# Create temp directory for parallel results
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Export variables for use in parallel processes
export OWNER API_KEY DESTINATION_ENDPOINT BASE_URL TEMP_DIR

echo "Fetching repository list for owner: $OWNER"
echo "Looking for endpoint: $DESTINATION_ENDPOINT"
echo "Output will be saved to: $OUTPUT_FILE"
echo "----------------------------------------"

# Fetch the list of repositories
REPOS_RESPONSE=$(curl -s -X 'GET' \
  "$BASE_URL/$OWNER/actions/security-summary" \
  -H 'accept: application/json' \
  -H "Authorization: $API_KEY")

if [ $? -ne 0 ]; then
    echo "Error: Failed to fetch repository list"
    exit 1
fi

# Count and display number of repos (excluding #all#)
REPO_COUNT=$(echo "$REPOS_RESPONSE" | jq -r '[.[].Repo | select(. != "#all#")] | length')
echo "Found $REPO_COUNT repositories"
echo "----------------------------------------"

# Function to process a single repository
process_repo() {
    local repo="$1"

    # Fetch baseline for this repository
    BASELINE_RESPONSE=$(curl -s -X 'GET' \
      "$BASE_URL/$OWNER/$repo/baseline" \
      -H 'accept: application/json' \
      -H "Authorization: $API_KEY")

    if [ $? -eq 0 ]; then
        # Check if the destination endpoint exists in the baseline
        ENDPOINT_FOUND=$(echo "$BASELINE_RESPONSE" | jq -r --arg endpoint "$DESTINATION_ENDPOINT" '
            .endpoints[]? | select(.endpoint == $endpoint) | .endpoint'
        )

        if [ -n "$ENDPOINT_FOUND" ]; then
            echo "✓ Found endpoint in $repo"
            # Write to temp file (repo name as filename to avoid conflicts)
            echo "$repo,https://app.stepsecurity.io/github/$OWNER/actions/baseline?tab=repositories&repository=$repo" > "$TEMP_DIR/$repo.csv"
        else
            echo "  No match in $repo"
        fi
    else
        echo "  Error fetching baseline for $repo"
    fi
}
export -f process_repo

# Process repos in parallel (10 concurrent requests)
echo "$REPOS_RESPONSE" | jq -r '.[].Repo | select(. != "#all#")' | xargs -P 10 -I {} bash -c 'process_repo "$@"' _ {}

# Combine results into final output file
echo "repo,baseline_link" > "$OUTPUT_FILE"
cat "$TEMP_DIR"/*.csv >> "$OUTPUT_FILE" 2>/dev/null

echo "----------------------------------------"
echo "Scan complete. Results saved to $OUTPUT_FILE"
echo "Repositories with endpoint '$DESTINATION_ENDPOINT':"
if [ -s "$OUTPUT_FILE" ] && [ "$(wc -l < "$OUTPUT_FILE")" -gt 1 ]; then
    tail -n +2 "$OUTPUT_FILE"
else
    echo "No repositories found with the specified endpoint."
fi
