#!/bin/bash
# Run tests with progress bar output
# Shows a tqdm-like progress bar during test execution

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT_FILE="/tmp/muesli-test-${TIMESTAMP}.txt"
PROGRESS_FILE="/tmp/muesli-test-progress-${TIMESTAMP}.txt"

# Parse arguments
TEST_TARGET=""
TEST_CLASS=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --unit-only)
      TEST_TARGET="MuesliTests"
      shift
      ;;
    --ui-only)
      TEST_TARGET="MuesliUITests"
      shift
      ;;
    --class)
      TEST_CLASS="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--unit-only|--ui-only] [--class ClassName]"
      exit 1
      ;;
  esac
done

cd "$PROJECT_DIR"

echo ""
echo "🧪 Muesli Test Suite"
echo "════════════════════════════════════════════════════════════"
echo ""

# Step 1: Enumerate tests to get total count
echo "📋 Enumerating tests..."
ENUM_OUTPUT=$(mktemp)

XCODEBUILD_ENUM_CMD="xcodebuild -project Muesli.xcodeproj -scheme Muesli -configuration Debug -destination 'platform=macOS' -enumerate-tests -test-enumeration-format json -test-enumeration-output-path -"

if [ -n "$TEST_TARGET" ]; then
  XCODEBUILD_ENUM_CMD="$XCODEBUILD_ENUM_CMD -only-testing:$TEST_TARGET"
elif [ -n "$TEST_CLASS" ]; then
  XCODEBUILD_ENUM_CMD="$XCODEBUILD_ENUM_CMD -only-testing:MuesliTests/$TEST_CLASS"
fi

# Try to enumerate tests
if eval "$XCODEBUILD_ENUM_CMD" > "$ENUM_OUTPUT" 2>/dev/null && [ -s "$ENUM_OUTPUT" ]; then
  # Parse JSON to count tests
  if command -v jq &> /dev/null; then
    TOTAL_TESTS=$(jq '[.tests[]?.tests[]?.tests[]?] | length' "$ENUM_OUTPUT" 2>/dev/null || echo "0")
  else
    # Fallback: try text format
    TOTAL_TESTS=$(xcodebuild -project Muesli.xcodeproj -scheme Muesli -configuration Debug -destination 'platform=macOS' -enumerate-tests -test-enumeration-format text -test-enumeration-output-path - 2>/dev/null | grep -c "test" || echo "0")
  fi
  
  if [ "$TOTAL_TESTS" -gt 0 ] 2>/dev/null; then
    echo "   Found $TOTAL_TESTS test cases"
  else
    TOTAL_TESTS=0
    echo "   Could not determine total (will show running count)"
  fi
else
  TOTAL_TESTS=0
  echo "   Could not enumerate tests (will show running count)"
fi

rm -f "$ENUM_OUTPUT"

echo ""
echo "▶ Running tests..."
echo ""

# Initialize progress file
echo "0" > "$PROGRESS_FILE"
echo "" >> "$PROGRESS_FILE"  # Current test name

# Function to update progress bar
update_progress() {
  local completed passed failed skipped current_test
  
  # Read progress from file
  completed=$(head -1 "$PROGRESS_FILE" 2>/dev/null || echo "0")
  current_test=$(tail -1 "$PROGRESS_FILE" 2>/dev/null || echo "")
  
  # Count from output file
  if [ -f "$OUTPUT_FILE" ]; then
    passed=$(grep -c "passed on" "$OUTPUT_FILE" 2>/dev/null || echo "0")
    failed=$(grep -c "failed on" "$OUTPUT_FILE" 2>/dev/null || echo "0")
    skipped=$(grep -c "skipped on" "$OUTPUT_FILE" 2>/dev/null || echo "0")
    completed=$((passed + failed + skipped))
  fi
  
  if [ "$TOTAL_TESTS" -gt 0 ] && [ "$completed" -le "$TOTAL_TESTS" ]; then
    local percent=$((completed * 100 / TOTAL_TESTS))
    local filled=$((percent / 2))  # 50 chars max for bar
    local empty=$((50 - filled))
    
    # Build progress bar
    local bar=""
    local i
    for ((i=0; i<filled; i++)); do bar="${bar}█"; done
    for ((i=0; i<empty; i++)); do bar="${bar}░"; done
    
    # Print progress bar (overwrite line)
    printf "\r   [%s] %3d%% (%d/%d)" "$bar" "$percent" "$completed" "$TOTAL_TESTS"
    if [ -n "$current_test" ]; then
      # Truncate long test names
      local test_display="${current_test:0:35}"
      [ ${#current_test} -gt 35 ] && test_display="${test_display}..."
      printf " %-40s" "$test_display"
    fi
  else
    # No total count, just show running count
    printf "\r   Running... (%d completed" "$completed"
    [ "$passed" -gt 0 ] && printf ", %d passed" "$passed"
    [ "$failed" -gt 0 ] && printf ", %d failed" "$failed"
    [ "$skipped" -gt 0 ] && printf ", %d skipped" "$skipped"
    printf ")"
    if [ -n "$current_test" ]; then
      local test_display="${current_test:0:25}"
      [ ${#current_test} -gt 25 ] && test_display="${test_display}..."
      printf " - %s" "$test_display"
    fi
  fi
}

# Start progress monitor in background
(
  while true; do
    # Check if xcodebuild is still running
    if ! pgrep -f "xcodebuild.*test" > /dev/null 2>&1; then
      sleep 0.5  # Wait a bit more for final output
      update_progress
      break
    fi
    update_progress
    sleep 0.3
  done
  echo ""  # Final newline
) &
PROGRESS_PID=$!

# Build xcodebuild command
XCODEBUILD_TEST_CMD="xcodebuild -project Muesli.xcodeproj -scheme Muesli -configuration Debug -destination 'platform=macOS' test"

if [ -n "$TEST_TARGET" ]; then
  XCODEBUILD_TEST_CMD="$XCODEBUILD_TEST_CMD -only-testing:$TEST_TARGET"
elif [ -n "$TEST_CLASS" ]; then
  XCODEBUILD_TEST_CMD="$XCODEBUILD_TEST_CMD -only-testing:MuesliTests/$TEST_CLASS"
fi

# Run tests and track progress
eval "$XCODEBUILD_TEST_CMD" 2>&1 | tee "$OUTPUT_FILE" | while IFS= read -r line; do
  # Extract test name from various xcodebuild output formats
  if [[ "$line" =~ Test\ Case\ \'([^\']+)\' ]] || [[ "$line" =~ Test\ case\ \'([^\']+)\' ]]; then
    local test_name="${BASH_REMATCH[1]}"
    # Extract just the test method name for display
    test_name="${test_name##*/}"
    echo "$test_name" >> "$PROGRESS_FILE"
    # Update completed count (will be recalculated from output)
    head -1 "$PROGRESS_FILE" > "$PROGRESS_FILE.tmp"
    echo "$test_name" >> "$PROGRESS_FILE.tmp"
    mv "$PROGRESS_FILE.tmp" "$PROGRESS_FILE"
  fi
  
  # Update completed count when tests finish
  if [[ "$line" =~ passed\ on ]] || [[ "$line" =~ failed\ on ]] || [[ "$line" =~ skipped\ on ]]; then
    local current_count=$(head -1 "$PROGRESS_FILE" 2>/dev/null || echo "0")
    current_count=$((current_count + 1))
    local current_test=$(tail -1 "$PROGRESS_FILE" 2>/dev/null || echo "")
    echo "$current_count" > "$PROGRESS_FILE"
    echo "$current_test" >> "$PROGRESS_FILE"
  fi
done

# Wait for progress monitor to finish
wait "$PROGRESS_PID" 2>/dev/null || true
rm -f "$PROGRESS_FILE"

# Extract final results from output file
echo ""
if grep -q "TEST SUCCEEDED" "$OUTPUT_FILE"; then
  echo "✅ Status: SUCCEEDED"
else
  echo "❌ Status: FAILED"
fi

# Count from output file (more accurate)
FINAL_PASSED=$(grep -c "passed on" "$OUTPUT_FILE" 2>/dev/null || echo "0")
FINAL_FAILED=$(grep -c "failed on" "$OUTPUT_FILE" 2>/dev/null || echo "0")
FINAL_SKIPPED=$(grep -c "skipped on" "$OUTPUT_FILE" 2>/dev/null || echo "0")

echo "📊 Passed: $FINAL_PASSED ✅"
echo "⏭️  Skipped: $FINAL_SKIPPED"
echo "❌ Failed: $FINAL_FAILED"

if [ "$FINAL_FAILED" -gt 0 ]; then
  echo ""
  echo "Failed tests:"
  grep "failed on" "$OUTPUT_FILE" | head -10 | sed 's/^/   /'
fi

echo ""
echo "📁 Output saved to: $OUTPUT_FILE"
