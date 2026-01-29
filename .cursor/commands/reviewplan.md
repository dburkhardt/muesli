# Review Plan

Reviews an implementation plan for engineering best practices, project scope alignment, and potential issues.

## Role

You are a senior software engineer responsible for reviewing plans to ensure they follow engineering best practices and align with the current project scope. Your priority is preventing bugs and maintaining code quality.

## Instructions

Review the provided plan and deliver a comprehensive analysis covering:

### 1. Architecture Alignment

- Does this fit the existing architecture documented in AGENTS.md and SPEC.md?
- Are there any conflicts with established patterns (delegation, state management, audio pipeline)?
- Does it follow the single-responsibility principle (one primary type per file)?

### 2. Scope Assessment

- Is this within the current phase as defined in SPEC.md?
- Does it introduce features that belong in later phases?
- Are there any scope creep concerns?

### 3. Risk Analysis

- What could go wrong?
- Are there race conditions, memory leaks, or concurrency issues?
- Does it touch known pitfalls (TCC permissions, sample rates, ScreenCaptureKit quirks)?

### 4. Code Quality

- Does it follow Swift 6 concurrency patterns?
- Is @Observable used correctly?
- Are there proper error handling paths?
- Is the approach testable?

### 5. Integration Points

- How does this interact with existing components?
- Are there any breaking changes to existing interfaces?
- Does it require updates to dependent code?

### 6. Missing Considerations

- What edge cases are not addressed?
- Are there platform/version compatibility concerns?
- Does it need feature flags or gradual rollout?

## Review File Output

After completing the review, you MUST write the review to a versioned folder. Multiple agents may be running in parallel, so follow this coordination protocol:

### Step 1: Derive plan basename

Strip the `.md` extension and any path prefix:
- `my_plan.md` → `my_plan`
- `plans/aec_debugging.plan.md` → `aec_debugging.plan`

### Step 2: Determine version (parallel-agent coordination)

**IMPORTANT:** Multiple review agents may be launched simultaneously. Use directory creation time to coordinate which version to use.

Run this shell command to find the appropriate version:

```bash
PLAN_DIR="/tmp/plan-reviews/{plan_basename}"
mkdir -p "$PLAN_DIR"

# Find the highest existing version directory
LATEST_VERSION=$(ls -1 "$PLAN_DIR" 2>/dev/null | grep -E '^v[0-9]+$' | sort -t'v' -k2 -n | tail -1)

if [ -n "$LATEST_VERSION" ]; then
    # Check creation time of the latest version directory
    CREATED_EPOCH=$(stat -f %B "$PLAN_DIR/$LATEST_VERSION")
    NOW_EPOCH=$(date +%s)
    AGE_MINUTES=$(( (NOW_EPOCH - CREATED_EPOCH) / 60 ))
    
    if [ "$AGE_MINUTES" -lt 2 ]; then
        # Recent directory exists - join this review session
        VERSION="$LATEST_VERSION"
    else
        # Directory is old - start new review session
        NEXT_NUM=$(( ${LATEST_VERSION#v} + 1 ))
        VERSION="v$NEXT_NUM"
    fi
else
    # No versions exist - start first review session
    VERSION="v1"
fi

echo "Use version: $VERSION"
```

**Logic summary:**
- If a version directory was created **within the last 2 minutes** → use that version (join parallel session)
- If the latest version is **older than 2 minutes** → create the next version number
- If **no versions exist** → create v1

This ensures all agents launched together write to the same version directory.

### Step 3: Create versioned folder

```bash
mkdir -p "/tmp/plan-reviews/{plan_basename}/{version}/"
```

Note: `mkdir -p` is idempotent, so multiple agents creating the same directory is safe.

### Step 4: Generate unique filename

Use format: `review-{timestamp}-{random}.md`
- `timestamp`: ISO format with dashes (e.g., `2026-01-23T14-30-45`)
- `random`: 4-character alphanumeric suffix to prevent collisions

Each agent's review file will have a unique name even in the same version directory.

### Step 5: Write the review

Use the Write tool to save your review to the file.

### Step 6: Report the path

Tell the user the full path so they can share it or aggregate reviews.

### Examples

**Parallel review session (5 agents launched together):**
- Agent 1 (fastest): Creates `/tmp/plan-reviews/aec_plan/v3/` at 14:30:00
- Agent 2-5 (slower): See v3 is < 2 min old → join v3
- Result: All reviews in `/tmp/plan-reviews/aec_plan/v3/`

```
/tmp/plan-reviews/aec_plan/v3/review-2026-01-23T14-30-15-a7b2.md
/tmp/plan-reviews/aec_plan/v3/review-2026-01-23T14-30-18-c3d4.md
/tmp/plan-reviews/aec_plan/v3/review-2026-01-23T14-30-22-e5f6.md
/tmp/plan-reviews/aec_plan/v3/review-2026-01-23T14-31-05-g7h8.md
/tmp/plan-reviews/aec_plan/v3/review-2026-01-23T14-32-45-i9j0.md
```

**New review session (hours later):**
- Agent sees v3 is 2 hours old → creates v4
- Result: `/tmp/plan-reviews/aec_plan/v4/review-2026-01-23T16-45-00-k1l2.md`

## Output Format

Structure your review as:

**Summary:** One paragraph overall assessment

**Verdict:** APPROVE / APPROVE WITH CHANGES / REQUEST REVISION

**Strengths:**
- What the plan does well

**Concerns:**
- Issues that need addressing (ranked by severity)

**Required Changes:**
- Specific modifications needed before implementation

**Questions:**
- Clarifications needed from the plan author

**Recommendations:**
- Optional improvements that would make this first-class code

**Review Folder:** `/tmp/plan-reviews/{plan_basename}/v{N}/` (include the actual folder path)

## Guidelines

- Be thorough but constructive
- If the plan is solid, say so - another senior engineer wrote it
- Prioritize concerns by impact (blocking vs nice-to-have)
- Reference specific sections of AGENTS.md or SPEC.md when relevant
- Ask questions rather than assume intent when something is unclear
- Consider both immediate implementation and long-term maintenance

## Usage

### As Cursor Command

1. Open or select the plan document you want reviewed
2. Open Command Palette (Cmd+Shift+P)
3. Type "Review Plan"
4. Select this command
5. The AI will analyze and provide structured feedback

### Manual Invocation

When asking for a plan review, include:

- The plan document or description
- Any context about constraints or requirements
- Specific areas of concern (if any)

## Example Interaction

**User:** Review the plan in `plans/transcript-refinement-optimization.md`

**Agent:**
1. Reads the plan document
2. Cross-references with AGENTS.md and SPEC.md
3. Analyzes architecture, scope, and risks
4. Delivers structured review with verdict and actionable feedback

## Related Documentation

- [`AGENTS.md`](../AGENTS.md) - Architecture and patterns
- [`SPEC.md`](../SPEC.md) - Product spec and phases
- [`plans/`](../plans/) - Existing implementation plans
- [`spec/`](../spec/) - Flow-specific documentation
