# Plan: Claude Code Hooks → Rainmeter Alert Integration

## Context

The user wants the Rainmeter widget to alert them when **any Claude Code terminal** on their device is either:
1. **Waiting for permission approval** (e.g., tool use confirmation)
2. **Idle/done and waiting for the next user prompt**

Claude Code's **hooks system** supports exactly this via the `Notification` event (with `idle_prompt` and `permission_prompt` matchers), plus `UserPromptSubmit` and `SessionEnd` for clearing alerts. Hooks are configured globally in `~/.claude/settings.json` and fire for all sessions.

## Design Overview

```
Claude Terminal A ──┐                    ┌──→ claude-sessions.json (tracking)
Claude Terminal B ──┼── Hook fires ──→ ClaudeHook.ps1 ──┤
Claude Terminal C ──┘   (stdin JSON)     ├──→ claude-status.inc (Rainmeter vars)
                                         └──→ Rainmeter !Refresh (instant update)
```

**Hook events used:**
| Event | Matcher | Action |
|---|---|---|
| `Notification` | `idle_prompt` | Mark session as "needs input" |
| `Notification` | `permission_prompt` | Mark session as "needs permission" |
| `UserPromptSubmit` | *(none)* | Clear alert for that session |
| `SessionEnd` | *(none)* | Remove session from tracking |

## Files to Create/Modify

### 1. NEW: `@Resources/ClaudeHook.ps1`
Hook handler script. Receives JSON on stdin from Claude Code hooks.

**Logic:**
- Parse event JSON from stdin (session_id, hook_event_name, notification_type, cwd)
- Load `claude-sessions.json` (create if missing), with simple file-lock retry
- On `Notification`: Add/update session entry with state (`idle` or `permission`), cwd, timestamp
- On `UserPromptSubmit`: Remove session from tracking (user is engaged)
- On `SessionEnd`: Remove session from tracking
- Purge stale sessions (>6 hours old) on every invocation
- Write summary to `claude-status.inc`:
  - `ClaudeAlertCount` - number of sessions needing attention
  - `ClaudePermissionCount` - how many need permission specifically
  - `ClaudeIdleCount` - how many are idle/waiting for input
  - `ClaudeAlertText` - display text (e.g., "2 terminals need input")
  - `ClaudeAlertType` - highest priority type (`permission` > `idle` > `none`)
- Call `Rainmeter.exe !Refresh "ClaudeUsage"` to instantly update the widget

### 2. NEW: `@Resources/claude-sessions.json`
Session tracking file (generated, gitignored). Example:
```json
{
  "sessions": {
    "abc-123": { "state": "idle", "cwd": "/path/to/project", "since": "2026-03-01T12:00:00" },
    "def-456": { "state": "permission", "cwd": "/other/project", "since": "2026-03-01T12:01:00" }
  }
}
```

### 3. NEW: `@Resources/claude-status.inc`
Generated Rainmeter variables file (gitignored). Example:
```ini
[Variables]
ClaudeAlertCount=2
ClaudePermissionCount=1
ClaudeIdleCount=1
ClaudeAlertType=permission
ClaudeAlertText=1 needs permission, 1 awaiting input
```

### 4. MODIFY: `ClaudeUsage.ini`
- Add `@Include2=#@#claude-status.inc` to import alert variables
- Add alert color variables: `AlertAmberColor`, `AlertRedColor`
- Add `[MeasureClaudeAlert]` Calc measure to drive show/hide logic via `IfCondition`
- Add alert banner meters (positioned between subtitle and 5-hour section):
  - `[MeterAlertBannerBg]` - Shape meter, amber for idle alerts, red for permission alerts
  - `[MeterAlertIcon]` - Warning icon (⚡ or ⚠)
  - `[MeterAlertText]` - Alert text showing count and type
  - All in `Group=AlertGroup`, hidden by default
- Adjust `[MeterBackground]` height to be dynamic (accommodate alert banner when visible)
- The measure uses `IfCondition` to `!ShowMeterGroup`/`!HideMeterGroup` AlertGroup

**Layout when alert active:**
```
┌─────────────────────────────┐
│ ✦ Claude Code               │ ← Header (unchanged)
│ Max 5 Plan | 88k tokens/5hr │ ← Subtitle (unchanged)
│ ⚠ 1 needs permission        │ ← NEW: Alert banner (amber/red)
│ 5-Hour Window          16%  │ ← Existing content shifts down
│ █████░░░░░░░░░░░░░░░░       │
│ ...                         │
```

**Layout when no alert (default):**
```
┌─────────────────────────────┐
│ ✦ Claude Code               │ ← Header
│ Max 5 Plan | 88k tokens/5hr │ ← Subtitle
│ 5-Hour Window          16%  │ ← No gap, alert banner hidden
│ ...                         │
```

### 5. MODIFY: `~/.claude/settings.json`
Add global hooks configuration (merged with existing settings):
```json
{
  "hooks": {
    "Notification": [
      {
        "matcher": "idle_prompt|permission_prompt",
        "hooks": [{
          "type": "command",
          "command": "powershell.exe -ExecutionPolicy Bypass -NoProfile -File \"C:/Users/kevin/OneDrive/Documents/Rainmeter/Skins/ClaudeUsage/@Resources/ClaudeHook.ps1\""
        }]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [{
          "type": "command",
          "command": "powershell.exe -ExecutionPolicy Bypass -NoProfile -File \"C:/Users/kevin/OneDrive/Documents/Rainmeter/Skins/ClaudeUsage/@Resources/ClaudeHook.ps1\""
        }]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [{
          "type": "command",
          "command": "powershell.exe -ExecutionPolicy Bypass -NoProfile -File \"C:/Users/kevin/OneDrive/Documents/Rainmeter/Skins/ClaudeUsage/@Resources/ClaudeHook.ps1\""
        }]
      }
    ]
  }
}
```

### 6. MODIFY: `.gitignore`
Add: `@Resources/claude-sessions.json`, `@Resources/claude-status.inc`

### 7. MODIFY: `CLAUDE.md`
Document the hooks integration, new files, and data flow.

## Key Design Decisions

- **Global hooks** (`~/.claude/settings.json`) so ALL Claude terminals trigger alerts, not just ones in this project
- **Session tracking via JSON file** to correctly handle multiple concurrent terminals
- **Stale session cleanup** (>6h) prevents orphaned alerts from crashed sessions
- **Rainmeter `!Refresh`** for instant widget updates (same pattern used by existing GetUsage.ps1)
- **PowerShell for hook script** (consistent with existing project; ~500ms startup is acceptable for notification events)
- **Alert between subtitle and content** for visibility without being intrusive

## Verification

1. **Test hook script manually**: Pipe sample JSON into ClaudeHook.ps1, verify claude-status.inc output
2. **Test Rainmeter display**: Set `ClaudeAlertCount=1` manually in claude-status.inc, refresh skin, verify banner appears
3. **Test end-to-end**: Open a second Claude terminal, trigger a permission prompt, verify the widget shows the alert
4. **Test clearing**: Submit a prompt in the alerting terminal, verify the alert clears
5. **Test multiple sessions**: Open 2+ terminals, verify count increments correctly
