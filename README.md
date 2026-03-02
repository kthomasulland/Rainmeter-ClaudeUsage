# Claude Code Usage Monitor

A Rainmeter skin that displays your Claude Code subscription usage (5-hour and 7-day rate limits) as a desktop widget. It fetches live data from the Anthropic API using your Claude Code credentials.

![Rainmeter](https://img.shields.io/badge/Rainmeter-Desktop%20Widget-blue)
![Windows](https://img.shields.io/badge/platform-Windows-lightgrey)

## Features

- Real-time 5-hour and 7-day utilization bars
- Color-coded status: green (<50%), yellow (50-80%), red (>=80%)
- Estimated tokens remaining in your current window
- Auto-refresh at configurable intervals
- Automatic OAuth token refresh

## Prerequisites

1. **[Rainmeter](https://www.rainmeter.net/)** installed on Windows
2. **[Claude Code](https://docs.anthropic.com/en/docs/claude-code)** installed and logged in
   - The skin reads your credentials from `~/.claude/.credentials.json`, which is created automatically when you log in to Claude Code
3. An active **Claude Pro or Max subscription**

## Installation

1. Clone or download this repository into your Rainmeter Skins folder:
   ```
   Documents\Rainmeter\Skins\ClaudeUsage\
   ```
2. In Rainmeter, right-click the tray icon > **Refresh All**
3. Navigate to **ClaudeUsage** > **ClaudeUsage.ini** and load the skin

The skin will immediately attempt to fetch your usage data on first load.

## Configuration

Open `ClaudeUsage.ini` and edit the `[Variables]` section to match your subscription:

| Variable | Default | Options |
|---|---|---|
| `PlanName` | `Max 5` | `Pro`, `Max 5`, `Max 20` — display name shown in the header |
| `MaxTokens` | `88000` | `44000` (Pro), `88000` (Max 5), `220000` (Max 20) — token limit per 5-hour window |
| `Scale` | `1.5` | UI scale factor (1.0 = 280px wide, 1.5 = 420px, 2.0 = 560px) |
| `RefreshMinutes` | `5` | Auto-refresh interval in minutes |

After editing, right-click the skin > **Refresh Skin** to apply changes.

## Usage

- The skin auto-refreshes at the configured interval
- Click **Refresh** in the footer to manually update
- Click the **Updated** timestamp to open the log file for troubleshooting
- Hover over the timestamp to see the last error status

## Troubleshooting

| Problem | Solution |
|---|---|
| Shows "Error" or 0% | Check that Claude Code is installed and you're logged in (`claude` in terminal) |
| Credentials not found | Verify `~/.claude/.credentials.json` exists |
| Token refresh fails | Re-login to Claude Code to get a fresh token |
| Skin doesn't load | Confirm the folder is in your Rainmeter Skins directory and the folder is named `ClaudeUsage` |

## File Structure

```
ClaudeUsage/
├── ClaudeUsage.ini          # Main skin config (edit this for settings)
├── @Resources/
│   ├── GetUsage.ps1         # PowerShell script that calls the API
│   ├── usage-data.inc       # Generated — current usage data (auto-created)
│   └── usage-log.txt        # Generated — script execution log (auto-created)
├── CLAUDE.md
└── README.md
```

## License

MIT
