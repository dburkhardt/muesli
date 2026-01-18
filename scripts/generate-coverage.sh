#!/bin/bash
# Generate code coverage report for Muesli
# This script runs tests with coverage enabled and generates a human-readable HTML report
#
# Usage:
#   ./scripts/generate-coverage.sh              # Use cached build (fast)
#   ./scripts/generate-coverage.sh --force-clean-build  # Clean build (slow)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
FORCE_CLEAN=false

# Parse arguments
for arg in "$@"; do
  case $arg in
    --force-clean-build)
      FORCE_CLEAN=true
      shift
      ;;
  esac
done

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  🧪 Muesli Code Coverage Report"
echo "════════════════════════════════════════════════════════════"
echo ""

# Clean previous coverage data only if requested
if [ "$FORCE_CLEAN" = true ]; then
  echo "🧹 Clean build mode - removing DerivedData..."
  rm -rf "${PROJECT_DIR}/DerivedData"
else
  echo "⚡ Fast mode - using cached build"
  echo "   (pass --force-clean-build for clean build)"
fi

echo ""
echo "▶ Running test suite with coverage..."
echo ""

# Run tests with coverage enabled
cd "$PROJECT_DIR"
xcodebuild \
  -project Muesli.xcodeproj \
  -scheme Muesli \
  -configuration Debug \
  -destination 'platform=macOS' \
  -enableCodeCoverage YES \
  -derivedDataPath DerivedData \
  test 2>&1 | tee "/tmp/muesli-coverage-${TIMESTAMP}.txt" | \
  grep -E "Test Suite|Test Case|passed|failed|^\*\*|Testing" || true

echo ""
echo "▶ Processing coverage data..."

# Find the xcresult bundle
XCRESULT=$(find DerivedData -name "*.xcresult" | head -1)

if [ -z "$XCRESULT" ]; then
  echo ""
  echo "❌ Error: No coverage data found"
  exit 1
fi

echo "   ✓ Coverage data located"
echo ""

# Generate JSON report
echo "▶ Generating reports..."
xcrun xccov view --report --json "$XCRESULT" > coverage.json
echo "   ✓ JSON report created"

# Extract and display summary
echo ""
echo "════════════════════════════════════════════════════════════"
echo "  📈 Coverage Summary"
echo "════════════════════════════════════════════════════════════"

python3 -c "
import json
import sys

def get_coverage_emoji(coverage):
    if coverage >= 80: return '🟢'
    elif coverage >= 70: return '🟡'
    elif coverage >= 50: return '🟠'
    else: return '🔴'

with open('coverage.json', 'r') as f:
    data = json.load(f)

print()
for target in data.get('targets', []):
    target_name = target.get('name', 'Unknown')
    if 'Test' in target_name:
        continue
    
    coverage = target.get('lineCoverage', 0) * 100
    emoji = get_coverage_emoji(coverage)
    print(f'{emoji} Target: {target_name}')
    print(f'   Overall Coverage: {coverage:.2f}%')
    print()
    
    # Show per-file coverage for main app files
    files = target.get('files', [])
    files_sorted = sorted(files, key=lambda x: x.get('lineCoverage', 0))
    
    # Count files by coverage level
    low = sum(1 for f in files if f.get('lineCoverage', 0) * 100 < 50 and 'Test' not in f.get('path', ''))
    medium = sum(1 for f in files if 50 <= f.get('lineCoverage', 0) * 100 < 70 and 'Test' not in f.get('path', ''))
    good = sum(1 for f in files if 70 <= f.get('lineCoverage', 0) * 100 < 80 and 'Test' not in f.get('path', ''))
    excellent = sum(1 for f in files if f.get('lineCoverage', 0) * 100 >= 80 and 'Test' not in f.get('path', ''))
    
    print(f'   Coverage Distribution:')
    if excellent > 0: print(f'      🟢 Excellent (≥80%%): {excellent} files')
    if good > 0: print(f'      🟡 Good (70-80%%): {good} files')
    if medium > 0: print(f'      🟠 Medium (50-70%%): {medium} files')
    if low > 0: print(f'      🔴 Low (<50%%): {low} files')
    print()
    
    # Show files needing attention
    low_coverage_files = [f for f in files_sorted if f.get('lineCoverage', 0) * 100 < 70 and 'Test' not in f.get('path', '')][:8]
    if low_coverage_files:
        print(f'   Files Needing Attention (<70%):')
        print('   ' + '─' * 56)
        for file_data in low_coverage_files:
            path = file_data.get('path', '')
            if not path:
                continue
            filename = path.split('/')[-1]
            file_coverage = file_data.get('lineCoverage', 0) * 100
            emoji = get_coverage_emoji(file_coverage)
            print(f'   {emoji} {filename:40s} {file_coverage:5.1f}%%')
    print()
"

# Generate text report
xcrun xccov view --report "$XCRESULT" > coverage-report.txt

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  ✅ Coverage Report Complete"
echo "════════════════════════════════════════════════════════════"
echo ""
echo "📁 Generated Files:"
echo "   • coverage.json - Machine-readable coverage data"
echo "   • coverage-report.txt - Detailed text report"
echo "   • /tmp/muesli-coverage-${TIMESTAMP}.txt - Full test output"
echo ""
echo "🔍 View in Xcode:"
echo "   Open Muesli.xcodeproj → Report Navigator (⌘9) → Coverage tab"
echo ""
echo "💡 Command-line coverage for specific file:"
echo "   xcrun xccov view --file <path> '$XCRESULT'"
echo ""
