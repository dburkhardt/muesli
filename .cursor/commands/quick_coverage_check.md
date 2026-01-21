# Quick Coverage Check

**Purpose:** Fast coverage check with just the essential numbers.

**When to use:** 
- Quick status check before/after making changes
- Verify tests still pass with coverage
- Check if you've improved coverage for specific files

---

## Command

```bash
cd /Users/dburkhardt/git-repos/muesli && ./scripts/generate-coverage.sh 2>&1 | tail -50
```

This shows just the summary at the end of the coverage run.

---

## Even Faster: Just Run Tests

If you only want to verify tests pass (no coverage analysis):

```bash
cd /Users/dburkhardt/git-repos/muesli
xcodebuild -project Muesli.xcodeproj -scheme Muesli -destination 'platform=macOS' test 2>&1 | grep -E "(Test Suite|PASSED|FAILED|Executed)"
```

---

## Check Coverage for Specific File

After generating coverage, check a specific file:

```bash
python3 << 'EOF'
import json
import sys

# File to check (change this)
target_file = "AudioCaptureService.swift"

with open('coverage.json', 'r') as f:
    data = json.load(f)

found = False
for target in data.get('targets', []):
    if 'Test' in target.get('name', ''):
        continue
    for file_data in target.get('files', []):
        path = file_data.get('path', '')
        filename = path.split('/')[-1]
        if filename == target_file:
            found = True
            coverage = file_data.get('lineCoverage', 0) * 100
            lines = file_data.get('executableLines', 0)
            covered = file_data.get('coveredLines', 0)
            print(f"\n{filename}:")
            print(f"  Coverage: {coverage:.2f}%")
            print(f"  Lines: {covered}/{lines}")
            if coverage >= 80:
                print("  Status: ✅ Good")
            elif coverage >= 50:
                print("  Status: ⚠️  Needs improvement")
            else:
                print("  Status: ❌ Low coverage")
            break
    if found:
        break

if not found:
    print(f"\n❌ File '{target_file}' not found in coverage data")
EOF
```

Change `target_file = "AudioCaptureService.swift"` to check different files.

---

## Compare Coverage Before/After

When adding tests, compare before and after:

```bash
# Before adding tests
./scripts/generate-coverage.sh > /dev/null 2>&1
BEFORE=$(python3 -c "import json; f=open('coverage.json'); d=json.load(f); t=[t for t in d['targets'] if 'Muesli.app' in t.get('name','')][0]; print(f\"{t['lineCoverage']*100:.2f}\")")
echo "Coverage before: $BEFORE%"

# (Add your tests here)

# After adding tests  
./scripts/generate-coverage.sh > /dev/null 2>&1
AFTER=$(python3 -c "import json; f=open('coverage.json'); d=json.load(f); t=[t for t in d['targets'] if 'Muesli.app' in t.get('name','')][0]; print(f\"{t['lineCoverage']*100:.2f}\")")
echo "Coverage after: $AFTER%"

# Calculate improvement
python3 -c "print(f'Improvement: {float('$AFTER') - float('$BEFORE'):.2f}%')"
```

---

## Related

For full detailed analysis with priorities, see: [generate_coverage_report.md](generate_coverage_report.md)
