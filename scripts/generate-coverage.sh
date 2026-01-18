#!/bin/bash
# Generate code coverage report for Muesli
# This script runs tests with coverage enabled and generates a human-readable HTML report

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

echo "🧪 Running tests with code coverage..."
echo ""

# Clean previous coverage data
rm -rf "${PROJECT_DIR}/DerivedData"
rm -f "${PROJECT_DIR}/coverage-${TIMESTAMP}.txt"

# Run tests with coverage enabled
cd "$PROJECT_DIR"
xcodebuild \
  -project Muesli.xcodeproj \
  -scheme Muesli \
  -configuration Debug \
  -destination 'platform=macOS' \
  -enableCodeCoverage YES \
  -derivedDataPath DerivedData \
  test 2>&1 | tee "coverage-${TIMESTAMP}.txt"

echo ""
echo "📊 Generating coverage report..."

# Find the xcresult bundle
XCRESULT=$(find DerivedData -name "*.xcresult" | head -1)

if [ -z "$XCRESULT" ]; then
  echo "❌ No coverage data found"
  exit 1
fi

echo "✅ Found coverage data: $XCRESULT"
echo ""

# Generate JSON report
xcrun xccov view --report --json "$XCRESULT" > coverage.json

# Extract and display summary
echo "📈 Coverage Summary:"
echo "==================="

python3 -c "
import json
import sys

with open('coverage.json', 'r') as f:
    data = json.load(f)

print()
for target in data.get('targets', []):
    target_name = target.get('name', 'Unknown')
    if 'Test' in target_name:
        continue
    
    coverage = target.get('lineCoverage', 0) * 100
    print(f'Target: {target_name}')
    print(f'Line Coverage: {coverage:.2f}%')
    print()
    
    # Show per-file coverage for main app files
    files = target.get('files', [])
    files_sorted = sorted(files, key=lambda x: x.get('lineCoverage', 0))
    
    print('Files with lowest coverage:')
    print('-' * 60)
    for file_data in files_sorted[:10]:
        path = file_data.get('path', '')
        if 'Test' in path or not path:
            continue
        filename = path.split('/')[-1]
        file_coverage = file_data.get('lineCoverage', 0) * 100
        print(f'  {filename:40s} {file_coverage:6.2f}%')
    print()
"

# Generate HTML report
echo "🌐 Generating HTML report..."
xcrun xccov view --report "$XCRESULT" > coverage-report.txt

echo ""
echo "✅ Coverage report complete!"
echo ""
echo "📁 Generated files:"
echo "  - coverage.json          - Machine-readable coverage data"
echo "  - coverage-report.txt    - Text coverage report"
echo "  - coverage-${TIMESTAMP}.txt - Full test output"
echo ""
echo "🔍 To view detailed coverage in Xcode:"
echo "  1. Open Muesli.xcodeproj in Xcode"
echo "  2. Go to the Report Navigator (⌘9)"
echo "  3. Select the latest test run"
echo "  4. Click the 'Coverage' tab"
echo ""
echo "💡 To view coverage for a specific file:"
echo "  xcrun xccov view --file <path> '$XCRESULT'"
echo ""
