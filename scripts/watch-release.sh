#!/bin/bash

# Watch GitHub Actions release workflow with timeout
# Usage: ./scripts/watch-release.sh

set -e

cd "$(dirname "$0")/.."

TIMEOUT_MINUTES=10
CHECK_INTERVAL=0.8
MAX_CHECKS=$((TIMEOUT_MINUTES * 60 * 10 / 8))

echo "⏱️  Watching release workflow (timeout: ${TIMEOUT_MINUTES} minutes)"
echo ""

check_count=0
start_time=$(date +%s)
last_print=0

while [ $check_count -lt $MAX_CHECKS ]; do
    run_info=$(gh run list --workflow=release.yml --limit 1 --json status,conclusion,displayTitle,databaseId,createdAt,updatedAt 2>/dev/null || echo "")
    
    if [ -z "$run_info" ] || [ "$run_info" == "[]" ]; then
        echo "❌ No workflow runs found"
        exit 1
    fi
    
    status=$(echo "$run_info" | jq -r '.[0].status')
    conclusion=$(echo "$run_info" | jq -r '.[0].conclusion')
    title=$(echo "$run_info" | jq -r '.[0].displayTitle')
    run_id=$(echo "$run_info" | jq -r '.[0].databaseId')
    created_at=$(echo "$run_info" | jq -r '.[0].createdAt')
    updated_at=$(echo "$run_info" | jq -r '.[0].updatedAt')
    
    # Calculate watch script elapsed time
    current_time=$(date +%s)
    watch_elapsed=$((current_time - start_time))
    watch_min=$((watch_elapsed / 60))
    watch_sec=$((watch_elapsed % 60))
    
    # Calculate runner time - use CURRENT time for in-progress, updated_at for completed
    if [ "$created_at" != "null" ]; then
        if [[ "$OSTYPE" == "darwin"* ]]; then
            created_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$created_at" "+%s" 2>/dev/null || echo "$start_time")
        else
            created_epoch=$(date -d "$created_at" +%s 2>/dev/null || echo "$start_time")
        fi
        
        # For in-progress builds, use current time; for completed, use updated time
        if [ "$status" == "in_progress" ] || [ "$status" == "queued" ]; then
            runner_elapsed=$((current_time - created_epoch))
        elif [ "$updated_at" != "null" ]; then
            if [[ "$OSTYPE" == "darwin"* ]]; then
                updated_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$updated_at" "+%s" 2>/dev/null || echo "$current_time")
            else
                updated_epoch=$(date -d "$updated_at" +%s 2>/dev/null || echo "$current_time")
            fi
            runner_elapsed=$((updated_epoch - created_epoch))
        else
            runner_elapsed=$((current_time - created_epoch))
        fi
        
        if [ $runner_elapsed -lt 0 ]; then
            runner_elapsed=0
        fi
        runner_min=$((runner_elapsed / 60))
        runner_sec=$((runner_elapsed % 60))
    else
        runner_min=0
        runner_sec=0
    fi
    
    # Check if workflow completed
    if [ "$status" != "in_progress" ] && [ "$status" != "queued" ] && [ "$status" != "waiting" ]; then
        echo ""
        echo "═══════════════════════════════════════"
        echo "Status: ${status}"
        echo "Result: ${conclusion}"
        echo "Run ID: ${run_id}"
        echo "Time:   ${runner_min}m ${runner_sec}s"
        echo "═══════════════════════════════════════"
        
        if [ "$conclusion" == "success" ]; then
            echo ""
            echo "🎉 Release workflow completed successfully!"
            echo ""
            echo "View release:"
            echo "  https://github.com/dburkhardt/muesli/releases"
            exit 0
        elif [ "$conclusion" == "failure" ]; then
            echo ""
            echo "❌ Release workflow failed"
            echo ""
            echo "View logs:"
            echo "  gh run view ${run_id} --log-failed"
            exit 1
        else
            echo "⚠️  Workflow completed with: ${conclusion}"
            exit 0
        fi
    fi
    
    # Print update every 2 seconds
    if [ $((watch_elapsed - last_print)) -ge 2 ]; then
        echo "[Watch: ${watch_min}m${watch_sec}s] Runner: ${runner_min}m${runner_sec}s | ${status} | Run ${run_id}"
        last_print=$watch_elapsed
    fi
    
    check_count=$((check_count + 1))
    sleep $CHECK_INTERVAL
done

# Timeout
echo ""
echo "⏰ Timeout reached (${TIMEOUT_MINUTES} minutes)"
echo "Run ID: ${run_id} | Status: ${status}"
echo ""
read -p "Continue for another ${TIMEOUT_MINUTES}m? (y/n) " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    exec "$0"
else
    echo "Check later: gh run list --workflow=release.yml"
    exit 0
fi
