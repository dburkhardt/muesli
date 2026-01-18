# Generate Coverage Report

**Purpose:** Run tests with code coverage enabled and generate a detailed coverage analysis report.

**When to use:** 
- Before creating a PR to check coverage
- After adding new tests to verify improvement
- To identify areas needing more test coverage
- To review agent work on test additions

---

## Quick Command

```bash
./scripts/generate-coverage.sh
```

This script will:
1. Run all tests with coverage enabled
2. Generate coverage reports (JSON, text)
3. Display coverage summary in terminal
4. Show files with lowest coverage

---

## Detailed Coverage Analysis

For a comprehensive analysis with prioritized action items, run:

```bash
cd /Users/dburkhardt/git-repos/muesli

# Run coverage
./scripts/generate-coverage.sh

# Generate detailed summary with priorities
python3 << 'EOF'
import json

with open('coverage.json', 'r') as f:
    data = json.load(f)

print()
print('=' * 70)
print('CODE COVERAGE REPORT - Muesli')
print('=' * 70)
print()

total_lines = 0
covered_lines = 0

for target in data.get('targets', []):
    target_name = target.get('name', 'Unknown')
    # Skip external dependencies
    if target_name in ['MLXLLM', 'Transformers', 'MLXLMCommon']:
        continue
    if 'Test' in target_name:
        continue
    
    coverage = target.get('lineCoverage', 0) * 100
    lines_count = target.get('executableLines', 0)
    covered_count = target.get('coveredLines', 0)
    
    total_lines += lines_count
    covered_lines += covered_count
    
    print(f'Target: {target_name}')
    print(f'Line Coverage: {coverage:.2f}%')
    print(f'Lines: {covered_count}/{lines_count}')
    print()
    
    # Categorize files by coverage
    files = target.get('files', [])
    
    high_coverage = []
    medium_coverage = []
    low_coverage = []
    no_coverage = []
    
    for file_data in files:
        path = file_data.get('path', '')
        if 'Test' in path or not path:
            continue
        filename = path.split('/')[-1]
        file_coverage = file_data.get('lineCoverage', 0) * 100
        lines = file_data.get('executableLines', 0)
        covered = file_data.get('coveredLines', 0)
        
        if file_coverage >= 80:
            high_coverage.append((filename, file_coverage, covered, lines))
        elif file_coverage >= 50:
            medium_coverage.append((filename, file_coverage, covered, lines))
        elif file_coverage > 0:
            low_coverage.append((filename, file_coverage, covered, lines))
        else:
            no_coverage.append((filename, file_coverage, covered, lines))
    
    # Sort
    high_coverage.sort(key=lambda x: x[1], reverse=True)
    medium_coverage.sort(key=lambda x: x[1])
    low_coverage.sort(key=lambda x: x[1])
    no_coverage.sort(key=lambda x: x[0])
    
    print('✅ HIGH COVERAGE (≥80%):')
    print('-' * 70)
    if high_coverage:
        for filename, cov, covered, lines in high_coverage:
            print(f'  {filename:45s} {cov:6.2f}% ({covered}/{lines})')
    else:
        print('  (none)')
    print()
    
    print('⚠️  MEDIUM COVERAGE (50-79%):')
    print('-' * 70)
    if medium_coverage:
        for filename, cov, covered, lines in medium_coverage:
            print(f'  {filename:45s} {cov:6.2f}% ({covered}/{lines})')
    else:
        print('  (none)')
    print()
    
    print('❌ LOW COVERAGE (<50%) - PRIORITY AREAS:')
    print('-' * 70)
    if low_coverage:
        # Identify critical files
        critical = ['AudioCaptureService', 'TranscriptionService', 
                   'FileOutputService', 'RecordingController']
        for filename, cov, covered, lines in low_coverage:
            base = filename.replace('.swift', '')
            marker = '🔴 CRITICAL' if any(c in base for c in critical) else '  '
            print(f'  {marker:12s} {filename:45s} {cov:6.2f}% ({covered}/{lines})')
    else:
        print('  (none)')
    print()
    
    print('🔴 NO COVERAGE (0%):')
    print('-' * 70)
    if no_coverage:
        count = len(no_coverage)
        print(f'  {count} files with no coverage')
        # Show top 10 by line count
        no_coverage_sorted = sorted(no_coverage, key=lambda x: x[3], reverse=True)
        for filename, cov, covered, lines in no_coverage_sorted[:10]:
            print(f'  {filename:45s} {cov:6.2f}% (0/{lines})')
        if count > 10:
            print(f'  ... and {count - 10} more files')
    else:
        print('  (none)')
    print()

if total_lines > 0:
    overall_coverage = (covered_lines / total_lines) * 100
    print('=' * 70)
    print(f'OVERALL PROJECT COVERAGE: {overall_coverage:.2f}%')
    print(f'Covered Lines: {covered_lines:,}/{total_lines:,}')
    print('=' * 70)
    print()
    
    # Status vs thresholds
    if overall_coverage >= 70:
        print('✅ PASSED: Meets 70% minimum threshold')
    else:
        gap = 70 - overall_coverage
        needed = int((total_lines * 0.70) - covered_lines)
        print(f'❌ BELOW THRESHOLD: {gap:.2f}% below 70% minimum')
        print(f'   Need ~{needed:,} more covered lines to reach 70%')
    print()
    
    # Show critical areas summary
    print('🎯 PRIORITY ACTION ITEMS:')
    print('-' * 70)
    print('Focus testing efforts on these critical services:')
    print('  1. AudioCaptureService.swift - Core audio capture')
    print('  2. TranscriptionService.swift - WhisperKit integration')
    print('  3. FileOutputService.swift - File I/O operations')
    print('  4. RecordingController.swift - Recording lifecycle')
    print()
    print('These 4 files are essential for app functionality and need 80%+ coverage.')
    print()

EOF
```

---

## View Coverage in Xcode

For line-by-line coverage visualization:

1. Open `Muesli.xcodeproj` in Xcode
2. Press `⌘9` to open Report Navigator
3. Select the latest test run
4. Click the "Coverage" tab
5. Click any file to see covered/uncovered lines
   - Green = covered
   - Red = not covered

---

## Understanding the Output

### Coverage Thresholds

- **✅ High (≥80%)**: Well tested, meets critical path standards
- **⚠️ Medium (50-79%)**: Partial coverage, needs improvement
- **❌ Low (<50%)**: Insufficient coverage, high priority for testing
- **🔴 No Coverage (0%)**: Untested code, very high risk

### Critical Files (Must be ≥80%)

1. **AudioCaptureService.swift** - System audio and microphone capture
2. **TranscriptionService.swift** - WhisperKit integration and processing
3. **FileOutputService.swift** - Transcript and audio file writing
4. **RecordingController.swift** - Recording state management

### Project Targets

- **Overall project**: 70% minimum
- **New code (PRs)**: 80% minimum (enforced by CI)
- **Critical services**: 90% target

---

## Interpreting Results

### If coverage is below 70%:
1. Review the "LOW COVERAGE" and "NO COVERAGE" sections
2. Prioritize critical services first (marked with 🔴 CRITICAL)
3. Add tests for core business logic before UI
4. Run coverage again to verify improvement

### If adding new tests:
1. Run coverage before: `./scripts/generate-coverage.sh`
2. Note the current percentage
3. Add your tests
4. Run coverage again
5. Compare the difference
6. Ensure critical files show improvement

### For PR reviews:
1. Generate coverage report
2. Check if new/modified files have ≥80% coverage
3. Verify no reduction in overall coverage
4. CI will automatically check and comment on PRs

---

## Generated Files

After running, these files will be created:

- `coverage.json` - Machine-readable coverage data
- `coverage-report.txt` - Detailed text report  
- `coverage-TIMESTAMP.txt` - Full test output with timestamp
- `DerivedData/` - Xcode build artifacts (can be deleted)

---

## Troubleshooting

**Tests fail:**
- Check test output in `coverage-TIMESTAMP.txt`
- Fix failing tests before analyzing coverage

**No coverage data:**
- Ensure Xcode scheme has coverage enabled (it should via shared scheme)
- Check that tests actually ran (look for "Test Suite" in output)

**Coverage seems wrong:**
- Make sure you're looking at Muesli.app target, not dependencies
- External libraries (MLXLLM, Transformers) don't need coverage
- Test files themselves don't count toward coverage

---

## Next Steps After Running

1. **Review the output** - Note current overall coverage percentage
2. **Identify gaps** - Look for 🔴 CRITICAL files with low coverage
3. **Create test plan** - Focus on critical services first
4. **Add tests** - Write tests for identified gaps
5. **Re-run coverage** - Verify improvement
6. **Commit changes** - When coverage improves meaningfully

---

## Example Output Interpretation

```
OVERALL PROJECT COVERAGE: 9.98%
❌ BELOW THRESHOLD: 60.02% below 70% minimum
Need ~12,854 more covered lines to reach 70%

🔴 CRITICAL AudioCaptureService.swift         1.57% (8/511)
```

**Translation:** 
- Project has 9.98% coverage (very low)
- Need about 13,000 more covered lines to reach 70% threshold
- AudioCaptureService is critical and only has 1.57% coverage
- This file should be the #1 priority for adding tests

---

## CI/CD Integration

This same coverage analysis runs automatically in CI on every PR:
- Results posted as PR comments
- Coverage badge updated in README
- Status checks enforce 80% coverage for new code
- View trends at: https://codecov.io/gh/dburkhardt/muesli

---

## Related Documentation

- [MuesliTests/README.md](../MuesliTests/README.md) - Test suite overview
- [AGENTS.md](../AGENTS.md) - Coverage policy and commands
- [codecov.yml](../codecov.yml) - Coverage configuration
