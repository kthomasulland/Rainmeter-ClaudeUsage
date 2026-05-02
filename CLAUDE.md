# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Rainmeter skin that displays Claude Code subscription usage (5-hour and 7-day rate limits) as a desktop widget on Windows. It fetches usage data from the Anthropic OAuth API using stored credentials. It also displays a status banner driven by Claude Code's hooks system, with three states: blue "Working..." (Claude is processing a prompt), amber "awaiting input" (idle), and red "needs permission" (blocked on a permission prompt).

## Architecture

**ClaudeUsage.ini** - Main Rainmeter skin configuration
- Defines the visual layout (280px base width, scalable via `Scale` variable)
- Uses `@Include` to import variables from `usage-data.inc`
- Uses `@Include2` to import alert state from `claude-status.inc`
- Runs PowerShell script via RunCommand plugin at configurable intervals
- Color-codes utilization: green (<50%), yellow (50-80%), red (>=80%)
- Calculates token remaining based on plan settings and API utilization percentage
- Shows/hides alert banner via `MeasureClaudeAlert` based on `ClaudeAlertCount`

**@Resources/GetUsage.ps1** - Data fetching script
- Reads OAuth token from `~/.claude/.credentials.json`
- Calls `https://api.anthropic.com/api/oauth/usage` with bearer auth
- Parses 5-hour and 7-day utilization windows
- Writes Rainmeter variables to `usage-data.inc` (UTF-8 without BOM)

**@Resources/usage-data.inc** - Generated variable file
- Written by PowerShell script, read by Rainmeter
- Contains: `FiveHourUtil`, `SevenDayUtil`, reset times, `LastUpdate`

**@Resources/ClaudeHook.ps1** - Hook handler script
- Receives JSON on stdin from Claude Code's hooks system
- Parses session_id, hook_event_name, notification_type, and cwd
- Maintains session state in `claude-sessions.json`
  - `UserPromptSubmit` → state=`working`
  - `Notification` (idle_prompt/permission_prompt) → state=`idle`/`permission` (overrides working)
  - `Stop` / `SessionEnd` → remove session
- Writes status summary to `claude-status.inc` (UTF-8 without BOM)
- Calls `Rainmeter.exe !Refresh` for instant widget updates

**@Resources/claude-sessions.json** - Session tracking file (generated, gitignored)
- Tracks active sessions by ID with state (`working`, `idle`, or `permission`), cwd, and timestamp
- Sessions older than 6 hours are automatically purged

**@Resources/claude-status.inc** - Generated status variables file (generated, gitignored)
- Contains: `ClaudeAlertCount` (perm+idle, drives sound/pulse), `ClaudeBannerCount` (perm+idle+working, drives banner visibility), `ClaudePermissionCount`, `ClaudeIdleCount`, `ClaudeWorkingCount`, `ClaudeAlertType`, `ClaudeAlertText`

## Data Flow

1. Auto-refresh counter triggers `GetUsage.ps1` at configured interval (default 5 min)
2. Script fetches from API, writes utilization data to `usage-data.inc`
3. Script's `FinishAction` triggers `[!Refresh]` to reload skin with new data
4. Rainmeter measures calculate tokens remaining based on plan's `MaxTokens` and utilization
5. User can also click "Refresh" button for manual update (resets interval timer)

## Hook-Based Alert Flow

1. Claude Code fires a hook event (Notification, UserPromptSubmit, or SessionEnd)
2. `ClaudeHook.ps1` receives the event JSON on stdin
3. Script updates `claude-sessions.json` (add/remove/purge sessions)
4. Script writes summary variables to `claude-status.inc`
5. Script calls `Rainmeter.exe !Refresh ClaudeUsage ClaudeUsage` for instant update
6. Rainmeter re-reads `claude-status.inc` via `@Include2`
7. `MeasureClaudeAlert` shows/hides the alert banner based on `ClaudeAlertCount`

## User-Configurable Settings

Edit these in the `[Variables]` section of `ClaudeUsage.ini`:

| Variable | Default | Description |
|----------|---------|-------------|
| `Scale` | 1.5 | UI scale factor (1.0 = 280px wide, 1.5 = 420px, 2.0 = 560px) |
| `PlanName` | Max 5 | Display name shown in header (Pro, Max 5, Max 20) |
| `MaxTokens` | 88000 | Token limit per 5-hour window (Pro=44000, Max5=88000, Max20=220000) |
| `RefreshMinutes` | 5 | Auto-refresh interval in minutes |
| `SoundEnabled` | 0 | Play honk.wav on alert (0=off, 1=on, togglable in widget footer) |

**Hook script path** is hardcoded in `~/.claude/settings.json`. If you move this skin's folder,
update the `command` values in all four hook entries (Notification, UserPromptSubmit, Stop, SessionEnd) to reflect the new path.

## Key Runtime Variables

**From API (in usage-data.inc):**
- `FiveHourUtil` / `SevenDayUtil` - Percentage utilization (0-100)
- `FiveHourHrs`, `FiveHourMins` - Time until 5-hour window resets
- `SevenDayDays`, `SevenDayHrs` - Time until 7-day window resets
- `LastUpdate` - Timestamp of last successful API call

**From hooks (in claude-status.inc):**
- `ClaudeAlertCount` - Sessions needing user attention: perm + idle (drives sound + pulse animation)
- `ClaudeBannerCount` - All sessions with a banner state: perm + idle + working (drives banner visibility)
- `ClaudePermissionCount` - Sessions blocked on a permission prompt
- `ClaudeIdleCount` - Sessions idle and waiting for user input
- `ClaudeWorkingCount` - Sessions actively processing a prompt
- `ClaudeAlertType` - Highest-priority type: `permission`, `idle`, `working`, or `none`
- `ClaudeAlertText` - Human-readable summary for display in the banner

**Calculated by Rainmeter measures:**
- `MeasureTokensRemainingK` - Remaining tokens in thousands
- `MeasureMaxTokensK` - Plan's max tokens in thousands (for subtitle display)

## Testing Changes

Reload the skin in Rainmeter or click the "Refresh" button in the widget footer. Check `usage-data.inc` to verify the PowerShell script output.

To test the alert banner, pipe a sample JSON event to `ClaudeHook.ps1`:
```powershell
'{"session_id":"test-001","hook_event_name":"Notification","notification_type":"idle_prompt","cwd":"C:/test"}' |
    powershell.exe -ExecutionPolicy Bypass -NoProfile -File "@Resources\ClaudeHook.ps1"
```
Then check `claude-status.inc` and `claude-sessions.json` for the expected output.
