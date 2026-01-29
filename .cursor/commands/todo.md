# Todo

Adds a new todo entry to `plans/todo.md` for tracking future work, features, and improvements.

## Usage

This command appends a new todo entry to the project's todo file.

### Steps

1. Run this command from the Cursor command palette
2. When prompted, provide:
   - **Category**: The area of the codebase (e.g., Audio, UI, Onboarding, Export, Testing)
   - **Brief description**: A short title for the todo
   - **Detailed description**: What needs to be done and why
   - **Requirements** (optional): Specific requirements or acceptance criteria

3. The command will:
   - Read the current `plans/todo.md`
   - Append a new todo section with proper formatting
   - Save the updated file

### Todo Format

New todos should follow this structure:

```markdown
## [Category] - Brief Description

Detailed description of the feature or improvement.

### Requirements

- Specific requirement 1
- Specific requirement 2

### Notes
- Additional context (optional)
```

## Instructions for Agent

When the user runs this command:

1. **Ask for todo details**:
   - Category (Audio, UI, Onboarding, Export, Testing, Infrastructure, Documentation, etc.)
   - Brief description (1 line)
   - Detailed description (1-3 sentences)
   - Requirements (bullet points, optional)

2. **Read the current todo file**:
   ```bash
   cat plans/todo.md
   ```

3. **Append the new todo** to `plans/todo.md` using the format above

4. **Confirm the addition** by showing the user what was added

## Example

**User input**:
- Category: UI
- Brief description: Add keyboard shortcuts for recording
- Detailed description: Allow users to start/stop recording with global keyboard shortcuts for faster workflow.
- Requirements:
  - Global hotkey to start recording
  - Global hotkey to stop recording
  - Configurable key bindings in preferences

**Result appended to `plans/todo.md`**:

```markdown
## UI - Add keyboard shortcuts for recording

Allow users to start/stop recording with global keyboard shortcuts for faster workflow.

### Requirements

- Global hotkey to start recording
- Global hotkey to stop recording
- Configurable key bindings in preferences
```

## Categories

Common categories for todos:

| Category | Description |
|----------|-------------|
| Audio | Audio capture, processing, file output |
| UI | User interface, views, controls |
| Onboarding | First-run experience, permissions |
| Export | Data export, external tool integration |
| Testing | Test coverage, UI tests, regression tests |
| Infrastructure | Build system, CI/CD, scripts |
| Documentation | AGENTS.md, SPEC.md, spec/ files |
| Performance | Optimization, memory, CPU usage |
| Transcription | WhisperKit, model management |
| Refinement | LLM refinement, transcript processing |

## When to Use Todos vs GitHub Issues

- **Use todos** for:
  - Quick notes about future improvements
  - Implementation details discovered during coding
  - Small features that don't need discussion

- **Use GitHub Issues** for:
  - Larger features that span multiple PRs
  - Bugs that need investigation or discussion
  - Work that needs to be tracked publicly
  - Features that need community input

## See Also

- Todo file: [`plans/todo.md`](../plans/todo.md)
- Agent guidelines: [`AGENTS.md`](../AGENTS.md) (see "Todo Tracking" section)
