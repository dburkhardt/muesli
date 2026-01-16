#!/bin/bash

# Watch GitHub Actions release workflow with timeout
# Usage: ./scripts/watch-release.sh

set -e

cd "$(dirname "$0")/.."

TIMEOUT_MINUTES=10
CHECK_INTERVAL=0.8
MAX_CHECKS=$((TIMEOUT_MINUTES * 60 * 10 / 8))  # Convert to 0.8s intervals

echo "⏱️  Watching release workflow (timeout: ${TIMEOUT_MINUTES} minutes)"
echo ""

check_count=0
start_time=$(date +%s)

while [ $check_count -lt $MAX_CHECKS ]; do
    # Get the latest workflow run with more details
    run_info=$(gh run list --workflow=release.yml --limit 1 --json status,conclusion,displayTitle,databaseId,createdAt 2>/dev/null || echo "")
    
    if [ -z "$run_info" ] || [ "$run_info" == "[]" ]; then
        echo "❌ No workflow runs found"
        exit 1
    fi
    
    # Parse status and details
    status=$(echo "$run_info" | jq -r '.[0].status')
    conclusion=$(echo "$run_info" | jq -r '.[0].conclusion')
    title=$(echo "$run_info" | jq -r '.[0].displayTitle' | cut -c1-60)
    run_id=$(echo "$run_info" | jq -r '.[0].databaseId')
    created_at=$(echo "$run_info" | jq -r '.[0].createdAt')
    
    # Calculate watch script elapsed time
    current_time=$(date +%s)
    watch_elapsed=$((current_time - start_time))
    watch_min=$((watch_elapsed / 60))
    watch_sec=$((watch_elapsed % 60))
    
    # Calculate GitHub runner elapsed time
    if [ "$created_at" != "null" ]; then
        runner_start=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$created_at" +%s 2>/dev/null || date -d "$created_at" +%s 2>/dev/null || echo "$start_time")
        runner_elapsed=$((current_time - runner_start))
        runner_min=$((runner_elapsed / 60))
        runner_sec=$((runner_elapsed % 60))
    else
        runner_min=0
        runner_sec=0
    fi
    
    # Check if workflow completed
    if [ "$status" != "in_progress" ] && [ "$status" != "queued" ] && [ "$status" != "waiting" ]; then
        printf "\r\033[K"  # Clear line
        echo "✅ Status: ${status} | Conclusion: ${conclusion}"
        echo ""
        echo "📋 Title: ${title}"
        echo "🔗 Run ID: ${run_id}"
        echo "⏱️  Runner time: ${runner_min}m ${runner_sec}s | Watch time: ${watch_min}m ${watch_sec}s"
        
        # Show result
        if [ "$conclusion" == "success" ]; then
            echo ""
            echo "🎉 Release workflow completed successfully!"
            echo ""
            echo "View release: https://github.com/dburkhardt/muesli/releases"
            exit 0
        elif [ "$conclusion" == "failure" ]; then
            echo ""
            echo "❌ Release workflow failed"
            echo ""
            echo "View logs: gh run view ${run_id} --log-failed"
            exit 1
        else
            echo ""
            echo "⚠️  Workflow completed with status: ${conclusion}"
            exit 0
        fi
    fi
    
    # Print in-progress status on single line
    printf "\r\033[K🔄 Runner: %dm %02ds | Watch: %dm %02ds | Status: %s | Run: %s" \
        $runner_min $runner_sec $watch_min $watch_sec "$status" "$run_id"
    
    check_count=$((check_count + 1))
    sleep $CHECK_INTERVAL
done

# Timeout reached
printf "\n\n"
echo "⏰ Timeout reached (${TIMEOUT_MINUTES} minutes)"
echo "The workflow is still running: ${status}"
echo ""
echo "View progress: gh run view ${run_id}"
echo ""
read -p "Continue waiting for another ${TIMEOUT_MINUTES} minutes? (y/n) " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo ""
    exec "$0"  # Re-run the script
else
    echo "Exiting. Check status later with: gh run list --workflow=release.yml --limit 1"
    exit 0
fi
