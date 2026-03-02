# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Rainmeter skin that displays Claude Code subscription usage (5-hour and 7-day rate limits) as a desktop widget on Windows. It fetches usage data from the Anthropic OAuth API using stored credentials.

## Architecture

**ClaudeUsage.ini** - Main Rainmeter skin configuration
- Defines the visual layout (280px base width, scalable via `Scale` variable)
- Uses `@Include` to import variables from `usage-data.inc`
- Runs PowerShell script via RunCommand plugin at configurable intervals
- Color-codes utilization: green (<50%), yellow (50-80%), red (>=80%)
- Calculates token remaining based on plan settings and API utilization percentage

**@Resources/GetUsage.ps1** - Data fetching script
- Reads OAuth token from `~/.claude/.credentials.json`
- Calls `https://api.anthropic.com/api/oauth/usage` with bearer auth
- Parses 5-hour and 7-day utilization windows
- Writes Rainmeter variables to `usage-data.inc` (UTF-8 without BOM)

**@Resources/usage-data.inc** - Generated variable file
- Written by PowerShell script, read by Rainmeter
- Contains: `FiveHourUtil`, `SevenDayUtil`, reset times, `LastUpdate`

## Data Flow

1. Auto-refresh counter triggers `GetUsage.ps1` at configured interval (default 5 min)
2. Script fetches from API, writes utilization data to `usage-data.inc`
3. Script's `FinishAction` triggers `[!Refresh]` to reload skin with new data
4. Rainmeter measures calculate tokens remaining based on plan's `MaxTokens` and utilization
5. User can also click "Refresh" button for manual update (resets interval timer)

## User-Configurable Settings

Edit these in the `[Variables]` section of `ClaudeUsage.ini`:

| Variable | Default | Description |
|----------|---------|-------------|
| `Scale` | 1.5 | UI scale factor (1.0 = 280px wide, 1.5 = 420px, 2.0 = 560px) |
| `PlanName` | Max 5 | Display name shown in header (Pro, Max 5, Max 20) |
| `MaxTokens` | 88000 | Token limit per 5-hour window (Pro=44000, Max5=88000, Max20=220000) |
| `RefreshMinutes` | 5 | Auto-refresh interval in minutes |

## Key Runtime Variables

**From API (in usage-data.inc):**
- `FiveHourUtil` / `SevenDayUtil` - Percentage utilization (0-100)
- `FiveHourHrs`, `FiveHourMins` - Time until 5-hour window resets
- `SevenDayDays`, `SevenDayHrs` - Time until 7-day window resets
- `LastUpdate` - Timestamp of last successful API call

**Calculated by Rainmeter measures:**
- `MeasureTokensRemainingK` - Remaining tokens in thousands
- `MeasureMaxTokensK` - Plan's max tokens in thousands (for subtitle display)

## Testing Changes

Reload the skin in Rainmeter or click the "Refresh" button in the widget footer. Check `usage-data.inc` to verify the PowerShell script output.
