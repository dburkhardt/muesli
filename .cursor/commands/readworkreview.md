# Read Work Reviews

Reads work review(s) from `/tmp/work-reviews/`, synthesizes the feedback, and creates an action plan using the CreatePlan tool.

## Instructions

### Step 1: Read the Reviews

You will be given either:
- A path to a single review file (e.g., `/tmp/work-reviews/my_plan/v3/review-2026-01-23T14-30-15-a7b2.md`)
- A path to a version directory (e.g., `/tmp/work-reviews/my_plan/v3/`)

If given a directory, read ALL `review-*.md` files in it.

### Step 2: Synthesize the Feedback

After reading all reviews, create a synthesis:

**Verdict Tally:**
Count the verdicts from all reviews:
- COMPLETE: X
- PARTIAL: X
- SIGNIFICANT_GAPS: X

**Plan Conformance Consensus:**
- What items are consistently marked as implemented?
- What items are consistently marked as missing?
- Any disagreements between reviewers?

**Breakage Risks:**
Compile all identified risks, noting:
- Which risks appear in multiple reviews (high confidence)
- Severity ratings (prioritize HIGH risks)
- Specific file locations mentioned

**Code Quality Issues:**
- Common issues identified across reviews
- Specific recommendations

**Recommendations:**
- Aggregate all recommendations
- Note which ones appear in multiple reviews

### Step 3: Print Summary

Output the synthesis to the user so they can see the review consensus before the plan is created.

### Step 4: Switch to Planning Mode and Create Action Plan

Call `SwitchMode` to enter planning mode, then use the `CreatePlan` tool to create an action plan.

The plan should:
1. Have a clear title like "Work Review Action Plan: {plan_basename}"
2. Include an overview summarizing what the reviews found
3. List specific todos for each issue to fix
4. Order todos by priority:
   - HIGH severity breakage risks first
   - MEDIUM severity risks second
   - Code quality issues third
   - Nice-to-have improvements last

**Plan structure:**
```markdown
# Work Review Action Plan: {plan_basename}

## Overview
Summary of what the reviews found, including verdict tally and overall assessment.

## Issues to Address

### HIGH Priority
- [ ] {Issue 1 from reviews}
- [ ] {Issue 2 from reviews}

### MEDIUM Priority
- [ ] {Issue 3}

### Code Quality
- [ ] {Quality issue 1}

### Recommendations
- [ ] {Improvement 1}
```

## Example Interaction

**User:** Read work reviews at `/tmp/work-reviews/aec_plan/v3/`

**Agent:**
1. Lists all `review-*.md` files in the directory
2. Reads each review file
3. Synthesizes the feedback:
   - Tallies verdicts: 3 PARTIAL, 2 COMPLETE
   - Identifies common breakage risks
   - Compiles code quality issues
4. Prints summary to user
5. Switches to planning mode
6. Calls CreatePlan with structured action plan
7. Reports the plan file location

## Notes

- Work reviews live in `/tmp/work-reviews/{plan_basename}/v{N}/`
- Multiple reviews in the same version directory were created by parallel agents
- Reviews from the same version should be weighted equally
- If reviews conflict, note the disagreement and include both perspectives in the plan
