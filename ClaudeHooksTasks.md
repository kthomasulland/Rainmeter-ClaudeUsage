# Implementation Task List: Claude Code Hooks → Rainmeter Alert Integration

Based on `ClaudeHooksPlan.md` and the existing codebase patterns.

---

## Overview

This feature wires Claude Code's hooks system into the Rainmeter widget so the desktop widget displays an alert banner whenever any Claude terminal is idle (waiting for your next message) or blocked on a permission prompt. The hook fires from `~/.claude/settings.json` (global, applies to all sessions), runs `ClaudeHook.ps1` which updates `claude-status.inc`, and calls `Rainmeter.exe !Refresh` for instant display.

---

## Task 1: Create `@Resources/ClaudeHook.ps1` — Hook Handler Script

- [x] **1.1 — Set up file paths and helper functions**

  File to create: `@Resources/ClaudeHook.ps1`

  Add the following path constants at the top of the script, following the same pattern used in `GetUsage.ps1` (`$PSScriptRoot` + filename):

  ```powershell
  $SessionsFile = "$PSScriptRoot\claude-sessions.json"
  $StatusFile   = "$PSScriptRoot\claude-status.inc"
  $LogFile      = "$PSScriptRoot\usage-log.txt"
  ```

  Add a `Write-Log` function identical in signature to the one in `GetUsage.ps1` (timestamp prefix, `Add-Content` with `-Encoding UTF8`). Reuse the same log file (`usage-log.txt`) so both scripts' output is in one place for easier debugging.

  Add a `Write-StatusData` function that mirrors `Write-UsageData` in `GetUsage.ps1`: use `[System.IO.File]::WriteAllLines($StatusFile, $Data, [System.Text.UTF8Encoding]::new($false))` to write UTF-8 without BOM. This is critical — Rainmeter cannot parse files with a BOM.

- [x] **1.2 — Parse hook event JSON from stdin**

  Claude Code pipes a JSON object to stdin when a hook fires. Read it with:

  ```powershell
  $inputJson = $input | Out-String
  $event = $inputJson | ConvertFrom-Json
  ```

  Extract the fields the script needs:
  - `$sessionId    = $event.session_id`
  - `$hookEvent    = $event.hook_event_name`   (e.g., `"Notification"`, `"UserPromptSubmit"`, `"SessionEnd"`)
  - `$notifType    = $event.notification_type`  (e.g., `"idle_prompt"`, `"permission_prompt"`; only present for `Notification` events)
  - `$cwd          = $event.cwd`

  Log the received event: `Write-Log "Hook received: event=$hookEvent, notifType=$notifType, session=$sessionId"`

  Gotcha: `$event.notification_type` will be `$null` for `UserPromptSubmit` and `SessionEnd` events — guard against this before using the value.

- [x] **1.3 — Load `claude-sessions.json` with file-lock retry**

  The sessions file is shared state that multiple concurrent hook processes could write simultaneously. Implement a simple retry loop:

  ```powershell
  $sessions = $null
  $retries = 5
  while ($retries -gt 0) {
      try {
          if (Test-Path $SessionsFile) {
              $raw = [System.IO.File]::ReadAllText($SessionsFile)
              $sessions = $raw | ConvertFrom-Json
          }
          break
      } catch {
          $retries--
          if ($retries -eq 0) { throw }
          Start-Sleep -Milliseconds 100
      }
  }
  ```

  If the file does not exist or the parsed object has no `.sessions` property, initialize to an empty hashtable:

  ```powershell
  if ($null -eq $sessions -or $null -eq $sessions.sessions) {
      $sessions = [PSCustomObject]@{ sessions = @{} }
  }
  ```

  Convert `.sessions` to a regular PowerShell hashtable for easy add/remove:

  ```powershell
  $sessionMap = @{}
  $sessions.sessions.PSObject.Properties | ForEach-Object { $sessionMap[$_.Name] = $_.Value }
  ```

- [x] **1.4 — Handle `Notification` event (add/update session)**

  When `$hookEvent -eq "Notification"`:

  Determine the state string:
  - `"permission_prompt"` → `$state = "permission"`
  - `"idle_prompt"` → `$state = "idle"`
  - Anything else → log and skip (do not add to tracking)

  Add or update the session entry in `$sessionMap`:

  ```powershell
  $sessionMap[$sessionId] = [PSCustomObject]@{
      state = $state
      cwd   = $cwd
      since = (Get-Date -Format "o")   # ISO 8601 round-trip format
  }
  ```

- [x] **1.5 — Handle `UserPromptSubmit` and `SessionEnd` events (remove session)**

  When `$hookEvent -eq "UserPromptSubmit"` or `$hookEvent -eq "SessionEnd"`:

  ```powershell
  if ($sessionMap.ContainsKey($sessionId)) {
      $sessionMap.Remove($sessionId)
      Write-Log "Removed session $sessionId (event: $hookEvent)"
  }
  ```

- [x] **1.6 — Purge stale sessions older than 6 hours**

  Run on every invocation, after handling the event, before writing output:

  ```powershell
  $cutoff = (Get-Date).AddHours(-6)
  $staleKeys = @($sessionMap.Keys | Where-Object {
      $entry = $sessionMap[$_]
      try { [DateTime]::Parse($entry.since) -lt $cutoff } catch { $true }
  })
  $staleKeys | ForEach-Object {
      Write-Log "Purging stale session: $_"
      $sessionMap.Remove($_)
  }
  ```

- [x] **1.7 — Save updated sessions back to `claude-sessions.json`**

  Reconstruct the object and write with a try/catch retry (same 5-attempt pattern as the read):

  ```powershell
  $outputObj = [PSCustomObject]@{ sessions = $sessionMap }
  $json = $outputObj | ConvertTo-Json -Depth 5
  [System.IO.File]::WriteAllText($SessionsFile, $json, [System.Text.UTF8Encoding]::new($false))
  ```

  Write without BOM for consistency, even though Rainmeter does not read this file.

  Note: The actual implementation converts `$sessionMap` (a hashtable) to a `PSCustomObject` before passing to `ConvertTo-Json` to avoid serializing .NET hashtable metadata properties (`Count`, `Keys`, `Values`, etc.).

- [x] **1.8 — Compute summary variables**

  Derive the four summary values from `$sessionMap`:

  ```powershell
  $permCount  = ($sessionMap.Values | Where-Object { $_.state -eq "permission" } | Measure-Object).Count
  $idleCount  = ($sessionMap.Values | Where-Object { $_.state -eq "idle" }       | Measure-Object).Count
  $totalCount = $permCount + $idleCount
  ```

  Determine `$alertType` (highest priority wins — `permission` beats `idle`):

  ```powershell
  if     ($permCount -gt 0)  { $alertType = "permission" }
  elseif ($idleCount -gt 0)  { $alertType = "idle" }
  else                        { $alertType = "none" }
  ```

  Build `$alertText` for display in the widget. Match the style of existing skin text (title-case, concise):

  ```powershell
  if ($alertType -eq "none") {
      $alertText = "All sessions clear"
  } elseif ($permCount -gt 0 -and $idleCount -gt 0) {
      $alertText = "$permCount needs permission, $idleCount awaiting input"
  } elseif ($permCount -gt 0) {
      $s = if ($permCount -eq 1) { "session" } else { "sessions" }
      $alertText = "$permCount $s need permission"
  } else {
      $s = if ($idleCount -eq 1) { "session" } else { "sessions" }
      $alertText = "$idleCount $s awaiting input"
  }
  ```

- [x] **1.9 — Write `claude-status.inc`**

  Use `Write-StatusData` (defined in task 1.1) with an array of strings, matching the exact format used by `GetUsage.ps1` when it writes `usage-data.inc`:

  ```powershell
  Write-StatusData @(
      "[Variables]",
      "ClaudeAlertCount=$totalCount",
      "ClaudePermissionCount=$permCount",
      "ClaudeIdleCount=$idleCount",
      "ClaudeAlertType=$alertType",
      "ClaudeAlertText=$alertText"
  )
  ```

  Important: The `.inc` file must start with `[Variables]` on the first line. Rainmeter ignores any section header it cannot map, but by convention the existing files always use `[Variables]`. Do not add a BOM.

- [x] **1.10 — Trigger Rainmeter refresh**

  After writing the status file, call Rainmeter's bang command to instantly reload the skin, using the same approach documented in the plan. The Rainmeter executable path is standard on Windows:

  ```powershell
  $rainmeterExe = "C:\Program Files\Rainmeter\Rainmeter.exe"
  if (Test-Path $rainmeterExe) {
      & $rainmeterExe "!Refresh" "ClaudeUsage" "ClaudeUsage"
      Write-Log "Triggered Rainmeter refresh"
  } else {
      Write-Log "WARNING: Rainmeter.exe not found at expected path"
  }
  ```

  Note: The bang syntax for refreshing a specific skin is `!Refresh "SkinFolder" "SkinFile"`. The skin folder is `ClaudeUsage` (the directory name) and the config is also `ClaudeUsage` (matching the `.ini` filename without extension). Verify this with `!Refresh ClaudeUsage ClaudeUsage` — if the skin does not reload, check Rainmeter's skin name in the Manage dialog.

  Alternative bang syntax to try if the above does not work: `!RefreshApp` (refreshes all skins).

- [x] **1.11 — Wrap the entire body in a try/catch**

  Wrap all logic from task 1.2 through 1.10 in a `try { } catch { Write-Log "ERROR: $($_.Exception.Message)" }`. The hook script must never crash visibly — Claude Code may display hook errors to the user if the process exits non-zero, which would be disruptive.

  Do not re-throw from the catch block; just log and exit cleanly.

---

## Task 2: Create `@Resources/claude-status.inc` — Initial State File

- [x] **2.1 — Write the initial zero-state file**

  File to create: `@Resources/claude-status.inc`

  This file will be overwritten at runtime by `ClaudeHook.ps1`, but it must exist with valid content before the skin is loaded for the first time, so Rainmeter does not error on the `@Include`. Create it manually with the "all clear" default values:

  ```ini
  [Variables]
  ClaudeAlertCount=0
  ClaudePermissionCount=0
  ClaudeIdleCount=0
  ClaudeAlertType=none
  ClaudeAlertText=All sessions clear
  ```

  Save as UTF-8 without BOM (use a hex editor or PowerShell to verify, since many text editors add a BOM silently on Windows).

  To create it safely from PowerShell:
  ```powershell
  [System.IO.File]::WriteAllLines(
      "...\@Resources\claude-status.inc",
      @("[Variables]","ClaudeAlertCount=0","ClaudePermissionCount=0","ClaudeIdleCount=0","ClaudeAlertType=none","ClaudeAlertText=All sessions clear"),
      [System.Text.UTF8Encoding]::new($false)
  )
  ```

---

## Task 3: Update `.gitignore` — Exclude Generated Files

- [x] **3.1 — Add the two new generated files to `.gitignore`**

  File to modify: `.gitignore`

  The current `.gitignore` contains:
  ```
  @Resources/usage-data.inc
  @Resources/usage-log.txt
  ```

  Append two new entries following the same pattern:
  ```
  @Resources/claude-sessions.json
  @Resources/claude-status.inc
  ```

  These are runtime-generated files that contain transient state and should not be committed. `claude-sessions.json` may contain working directory paths of open projects (privacy concern). `claude-status.inc` is ephemeral output.

---

## Task 4: Modify `ClaudeUsage.ini` — Add Alert Banner UI

- [x] **4.1 — Add `@Include2` for the new status file**

  File to modify: `ClaudeUsage.ini`

  After the existing `@Include` line (line 15), add:

  ```ini
  @Include2=#@#claude-status.inc
  ```

  Rainmeter supports multiple `@Include` directives numbered sequentially (`@Include`, `@Include2`, `@Include3`, etc.). The `#@#` prefix resolves to the skin's `@Resources` folder, consistent with how `usage-data.inc` is included.

- [x] **4.2 — Add alert color variables to `[Variables]`**

  In the `[Variables]` section, alongside the existing color definitions (`GreenColor`, `YellowColor`, `RedColor`), add:

  ```ini
  AlertAmberColor=255,170,0,255
  AlertRedColor=220,53,34,255
  AlertTextColor=255,255,255,255
  ```

  `AlertAmberColor` is used for idle alerts (attention needed but not blocking). `AlertRedColor` is used for permission alerts (action required to unblock Claude). These are visually distinct from the existing `YellowColor` and `RedColor` used for usage bar coloring.

- [x] **4.3 — Add `[MeasureClaudeAlert]` Calc measure**

  Add a new measure after the existing bar measures (e.g., after `[MeasureSevenDayBar]`) but before the meters section:

  ```ini
  [MeasureClaudeAlert]
  Measure=Calc
  Formula=#ClaudeAlertCount#
  DynamicVariables=1
  IfCondition=(#ClaudeAlertCount# > 0)
  IfTrueAction=[!ShowMeterGroup AlertGroup][!UpdateMeterGroup AlertGroup][!Redraw]
  IfFalseAction=[!HideMeterGroup AlertGroup][!Redraw]
  ```

  This measure drives the show/hide of the alert banner group. It runs on every skin update cycle. The `DynamicVariables=1` flag is required so Rainmeter re-reads `#ClaudeAlertCount#` from the included file on each update, consistent with how `MeasureFiveHourBar` reads `#FiveHourUtil#`.

- [x] **4.4 — Add alert color-switching logic to `[MeasureClaudeAlert]`**

  Extend the measure from 4.3 to also update the banner background color based on alert type. Add to the `IfTrueAction`:

  ```ini
  IfTrueAction=[!ShowMeterGroup AlertGroup][!UpdateMeterGroup AlertGroup][!SetOption MeterAlertBannerBg Shape "Rectangle 0,0,(#Width#),(28*#Scale#),(4*#Scale#) | Fill Color #AlertAmberColor# | StrokeWidth 0"][!UpdateMeter MeterAlertBannerBg][!Redraw]
  ```

  Then add a second condition for permission alerts specifically:

  ```ini
  IfCondition2=(#ClaudeAlertCount# > 0) && ("#ClaudeAlertType#" = "permission")
  IfTrueAction2=[!SetOption MeterAlertBannerBg Shape "Rectangle 0,0,(#Width#),(28*#Scale#),(4*#Scale#) | Fill Color #AlertRedColor# | StrokeWidth 0"][!UpdateMeter MeterAlertBannerBg][!Redraw]
  ```

  Gotcha: String comparison in Rainmeter `IfCondition` requires quoting the variable and using `=` (not `==`). Number comparisons use unquoted variables.

- [x] **4.5 — Insert alert banner meters between subtitle and 5-hour section**

  The plan calls for the alert banner to appear between `[MeterSubtitle]` and `[MeterFiveHourLabel]`. All three new meters must belong to `Group=AlertGroup` so the show/hide bang from task 4.3 controls them as a unit.

  Insert after `[MeterSubtitle]` and before `[MeterFiveHourLabel]`:

  ```ini
  ; --- Alert Banner (hidden by default, shown when ClaudeAlertCount > 0) ---
  [MeterAlertBannerBg]
  Meter=Shape
  X=#Padding#
  Y=(8*#Scale#)R
  Shape=Rectangle 0,0,(#Width#-#Padding#*2),(28*#Scale#),(4*#Scale#) | Fill Color #AlertAmberColor# | StrokeWidth 0
  Group=AlertGroup
  Hidden=1
  DynamicVariables=1

  [MeterAlertIcon]
  Meter=String
  X=(#Padding#+6*#Scale#)
  Y=(4*#Scale#)r
  FontFace=Segoe UI Symbol
  FontSize=(10*#Scale#)
  FontColor=#AlertTextColor#
  AntiAlias=1
  Text=[\x26A0]
  Group=AlertGroup
  Hidden=1
  DynamicVariables=1

  [MeterAlertText]
  Meter=String
  X=(6*#Scale#)R
  Y=0r
  FontFace=#FontFace#
  FontSize=#FontSizeSmall#
  FontWeight=500
  FontColor=#AlertTextColor#
  AntiAlias=1
  Text=#ClaudeAlertText#
  DynamicVariables=1
  Group=AlertGroup
  Hidden=1
  ```

  The `[\x26A0]` Unicode escape is the warning sign character (⚠), rendered via `Segoe UI Symbol` font, consistent with how the existing `[MeterIcon]` renders `[\x2726]` (the four-pointed star ✦).

  Positioning notes:
  - `MeterAlertBannerBg` uses `Y=(8*#Scale#)R` (relative to `MeterSubtitle` bottom) to add a gap between subtitle and banner.
  - `MeterAlertIcon` uses `Y=(4*#Scale#)r` (relative to banner top, small inset for vertical centering).
  - `MeterAlertText` uses `X=(6*#Scale#)R` (relative to icon right) and `Y=0r` (same Y as icon) to sit beside the icon.

  After the three alert meters, the existing `[MeterFiveHourLabel]` must use a Y position that accounts for the banner height when it is visible. Since Rainmeter meters with `Hidden=1` still occupy layout space by default when using relative positioning (`R`/`r`), verify actual behavior. If hidden meters do NOT contribute to layout flow, the `[MeterFiveHourLabel]` offset can remain as-is. If they DO contribute, a conditional offset is needed — see task 4.6.

- [x] **4.6 — Adjust `[MeterFiveHourLabel]` Y position for banner**

  The current `[MeterFiveHourLabel]` uses:
  ```ini
  Y=(12*#Scale#)R
  ```
  This is a relative offset from `MeterSubtitle`'s bottom edge.

  After the alert meters are inserted above it, `MeterFiveHourLabel` must use:
  ```ini
  Y=(8*#Scale#)R
  ```
  (relative to `MeterAlertBannerBg`'s bottom when alert is shown, or to subtitle's bottom when hidden — whichever is the last visible meter's bottom edge in the stack).

  Note: Rainmeter's `R`/`r` relative positioning is computed at render time based on the _previous meter in source order_, not the previous _visible_ meter. Because `MeterAlertBannerBg` is declared before `MeterFiveHourLabel` in the file, `R` on `MeterFiveHourLabel` will always be relative to `MeterAlertBannerBg`'s bottom, whether or not it is hidden.

  This means when the alert is hidden, there will be extra whitespace. To handle this cleanly:
  - Use an absolute Y position for `MeterFiveHourLabel` rather than a relative one.
  - Or, use the `IfCondition`/`IfTrueAction` in `MeasureClaudeAlert` to dynamically `!SetOption MeterFiveHourLabel Y` between the two values and `!UpdateMeter MeterFiveHourLabel`.

  Recommended approach (simplest): Switch `MeterFiveHourLabel` to an absolute Y and also update it dynamically:

  In `MeasureClaudeAlert`:
  ```ini
  IfTrueAction=[... existing actions ...][!SetOption MeterFiveHourLabel Y "(headerH + bannerH)*#Scale#"][!UpdateMeter MeterFiveHourLabel]
  IfFalseAction=[... existing actions ...][!SetOption MeterFiveHourLabel Y "(headerH)*#Scale#"][!UpdateMeter MeterFiveHourLabel]
  ```

  Measure the actual pixel offsets by loading the skin and inspecting layout. The header (icon + title row + subtitle row) spans roughly 46 scaled units from the top. The banner adds another 36 scaled units (8 gap + 28 height).

  Implementation note: Used absolute Y values `(55*#Scale#)` without banner and `(87*#Scale#)` with banner, calculated from the header pixel stack audit (task 7.1). `MeterFiveHourPercent` is also updated in the same action since it uses `Y=0r` relative to `MeterFiveHourLabel`.

- [x] **4.7 — Adjust `[MeterBackground]` height for alert banner**

  The current background rectangle is hardcoded:
  ```ini
  Shape=Rectangle 0,0,(#Width#),(215*#Scale#),(6*#Scale#) | Fill Color 20,20,25,230 | StrokeWidth 0
  ```

  The `215` covers the current layout height. When the alert banner is visible, the total content height increases by approximately 36 units (8 gap + 28 banner height). Use `MeasureClaudeAlert`'s actions to dynamically update the background shape:

  ```ini
  IfTrueAction=[... existing ...][!SetOption MeterBackground Shape "Rectangle 0,0,(#Width#),(251*#Scale#),(6*#Scale#) | Fill Color 20,20,25,230 | StrokeWidth 0"][!UpdateMeter MeterBackground]
  IfFalseAction=[... existing ...][!SetOption MeterBackground Shape "Rectangle 0,0,(#Width#),(215*#Scale#),(6*#Scale#) | Fill Color 20,20,25,230 | StrokeWidth 0"][!UpdateMeter MeterBackground]
  ```

  Note: The `Shape2` gradient overlay on `MeterBackground` does not need to change height since it only covers the top gradient area.

  Gotcha: The exact pixel counts (215, 251) must be verified empirically. Use `DynamicWindowSize=1` (already set in `[Rainmeter]`) to confirm the skin window auto-sizes — if so, only the background rectangle needs manual adjustment, not the window itself.

---

## Task 5: Modify `~/.claude/settings.json` — Register Global Hooks

- [x] **5.1 — Merge hook configuration into existing settings**

  File to modify: `C:\Users\kevin\.claude\settings.json`

  The current file content is:
  ```json
  {
    "enabledPlugins": {
      "github@claude-plugins-official": true,
      "commit-commands@claude-plugins-official": true,
      "claude-md-management@claude-plugins-official": true
    },
    "autoUpdatesChannel": "latest"
  }
  ```

  Add a `"hooks"` key at the top level. The full merged file should be:

  ```json
  {
    "enabledPlugins": {
      "github@claude-plugins-official": true,
      "commit-commands@claude-plugins-official": true,
      "claude-md-management@claude-plugins-official": true
    },
    "autoUpdatesChannel": "latest",
    "hooks": {
      "Notification": [
        {
          "matcher": "idle_prompt|permission_prompt",
          "hooks": [
            {
              "type": "command",
              "command": "powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File \"C:/Users/kevin/OneDrive/Documents/Rainmeter/Skins/ClaudeUsage/@Resources/ClaudeHook.ps1\""
            }
          ]
        }
      ],
      "UserPromptSubmit": [
        {
          "hooks": [
            {
              "type": "command",
              "command": "powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File \"C:/Users/kevin/OneDrive/Documents/Rainmeter/Skins/ClaudeUsage/@Resources/ClaudeHook.ps1\""
            }
          ]
        }
      ],
      "SessionEnd": [
        {
          "hooks": [
            {
              "type": "command",
              "command": "powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File \"C:/Users/kevin/OneDrive/Documents/Rainmeter/Skins/ClaudeUsage/@Resources/ClaudeHook.ps1\""
            }
          ]
        }
      ]
    }
  }
  ```

  Key notes:
  - Use forward slashes in the path even though it is a Windows path — this is inside a JSON string that PowerShell will interpret.
  - The `-WindowStyle Hidden` flag prevents a PowerShell console window from flashing on screen every time a hook fires.
  - The `matcher` on `Notification` is a regex `idle_prompt|permission_prompt` — this filters to only the two notification types the widget cares about.
  - `UserPromptSubmit` and `SessionEnd` have no `matcher` key; they match all occurrences.
  - Hooks are global: they fire for every Claude Code session on the machine, in every working directory.

  Gotcha: JSON does not allow trailing commas. Validate the file with `Get-Content settings.json | ConvertFrom-Json` in PowerShell after editing.

---

## Task 6: Update `CLAUDE.md` — Document the Hooks Integration

- [x] **6.1 — Add new files to the Architecture section**

  File to modify: `CLAUDE.md`

  After the existing `**@Resources/usage-data.inc**` entry, add:

  ```markdown
  **@Resources/ClaudeHook.ps1** - Hook handler script
  - Receives JSON on stdin from Claude Code's hooks system
  - Parses session_id, hook_event_name, notification_type, and cwd
  - Maintains session state in `claude-sessions.json`
  - Writes alert summary to `claude-status.inc` (UTF-8 without BOM)
  - Calls `Rainmeter.exe !Refresh` for instant widget updates

  **@Resources/claude-sessions.json** - Session tracking file (generated, gitignored)
  - Tracks active sessions by ID with state (`idle` or `permission`), cwd, and timestamp
  - Sessions older than 6 hours are automatically purged

  **@Resources/claude-status.inc** - Generated alert variables file (generated, gitignored)
  - Contains: `ClaudeAlertCount`, `ClaudePermissionCount`, `ClaudeIdleCount`, `ClaudeAlertType`, `ClaudeAlertText`
  ```

- [x] **6.2 — Update the Data Flow section**

  Add a second data flow description after the existing one:

  ```markdown
  ## Hook-Based Alert Flow

  1. Claude Code fires a hook event (Notification, UserPromptSubmit, or SessionEnd)
  2. `ClaudeHook.ps1` receives the event JSON on stdin
  3. Script updates `claude-sessions.json` (add/remove/purge sessions)
  4. Script writes summary variables to `claude-status.inc`
  5. Script calls `Rainmeter.exe !Refresh ClaudeUsage ClaudeUsage` for instant update
  6. Rainmeter re-reads `claude-status.inc` via `@Include2`
  7. `MeasureClaudeAlert` shows/hides the alert banner based on `ClaudeAlertCount`
  ```

- [x] **6.3 — Add hooks-specific variables to the Runtime Variables section**

  Under the "Calculated by Rainmeter measures" subsection, add:

  ```markdown
  **From hooks (in claude-status.inc):**
  - `ClaudeAlertCount` - Total sessions needing attention (0 = no alert)
  - `ClaudePermissionCount` - Sessions blocked on a permission prompt
  - `ClaudeIdleCount` - Sessions idle and waiting for user input
  - `ClaudeAlertType` - Highest-priority type: `permission`, `idle`, or `none`
  - `ClaudeAlertText` - Human-readable summary for display in the banner
  ```

- [x] **6.4 — Add hook configuration note to User-Configurable Settings**

  Add a note after the settings table:

  ```markdown
  **Hook script path** is hardcoded in `~/.claude/settings.json`. If you move this skin's folder,
  update the `command` values in all three hook entries to reflect the new path.
  ```

---

## Task 7: Verify Layout Math and Pixel Values

- [x] **7.1 — Manually audit the pixel heights in `MeterBackground`**

  Before implementing task 4.7, add up the actual scaled pixel heights of all meters in the skin at `Scale=1.5` to confirm that `215` is the correct base height and `251` (215 + 36) is the correct expanded height.

  The layout stack from top to bottom (all values × `Scale`):
  | Element | Height (unscaled px) | Notes |
  |---|---|---|
  | Top padding | 15 | `#Padding#` |
  | Icon/title row | ~20 | FontSizeLarge=14 + leading |
  | Subtitle row | ~14 | FontSizeSmall=9 |
  | Gap to 5-hr label | 12 | `Y=(12*#Scale#)R` on MeterFiveHourLabel |
  | 5-hr label row | ~14 | FontSize=10 |
  | Gap to bar | 5 | `Y=(5*#Scale#)R` on MeterFiveHourBarBg |
  | Bar height | 12 | `#BarHeight#` |
  | Gap to reset time | 6 | `Y=(6*#Scale#)R` on MeterFiveHourTime |
  | Reset/tokens row | ~12 | FontSizeSmall=9 |
  | Gap to 7-day | 16 | `Y=(16*#Scale#)R` on MeterSevenDayLabel |
  | 7-day label row | ~14 | FontSize=10 |
  | Gap to bar | 5 | same as above |
  | Bar height | 12 | same |
  | Gap to reset time | 6 | same |
  | Reset row | ~12 | same |
  | Gap to divider | 14 | `Y=(14*#Scale#)R` on MeterDivider |
  | Divider | 1 | 1px line |
  | Gap to last update | 10 | `Y=(10*#Scale#)R` on MeterLastUpdate |
  | Last update row | ~10 | FontSize=8 |
  | Bottom spacer | 5 | MeterBottomSpacer H |

  Tally this to verify the `215` constant. The alert banner adds: 8 (gap before banner) + 28 (banner height) = 36, giving `251`. Adjust both constants if the tally differs.

---

## Testing & Verification

- [x] **T1 — Verify `claude-status.inc` is valid UTF-8 without BOM**

  After creating the initial file (task 2.1), open it in a hex editor or run:
  ```powershell
  $bytes = [System.IO.File]::ReadAllBytes("...\claude-status.inc")
  if ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { "HAS BOM - FIX THIS" } else { "No BOM - OK" }
  ```
  Rainmeter will fail to parse the `[Variables]` section if a BOM is present.

  **Result: PASS** — No BOM detected.

- [x] **T2 — Test `ClaudeHook.ps1` manually with piped JSON**

  Test each event type by piping sample JSON directly into the script from a PowerShell terminal:

  ```powershell
  # Simulate idle_prompt notification
  '{"session_id":"test-001","hook_event_name":"Notification","notification_type":"idle_prompt","cwd":"C:/some/project"}' |
      powershell.exe -ExecutionPolicy Bypass -NoProfile -File "C:\Users\kevin\OneDrive\Documents\Rainmeter\Skins\ClaudeUsage\@Resources\ClaudeHook.ps1"

  # Check output
  Get-Content "C:\Users\kevin\OneDrive\Documents\Rainmeter\Skins\ClaudeUsage\@Resources\claude-status.inc"
  Get-Content "C:\Users\kevin\OneDrive\Documents\Rainmeter\Skins\ClaudeUsage\@Resources\claude-sessions.json"
  ```

  Expected `claude-status.inc`:
  ```
  [Variables]
  ClaudeAlertCount=1
  ClaudePermissionCount=0
  ClaudeIdleCount=1
  ClaudeAlertType=idle
  ClaudeAlertText=1 session awaiting input
  ```

  **Result: PASS** — Output matches expected.

- [x] **T3 — Test permission_prompt notification**

  ```powershell
  '{"session_id":"test-002","hook_event_name":"Notification","notification_type":"permission_prompt","cwd":"C:/other/project"}' |
      powershell.exe -ExecutionPolicy Bypass -NoProfile -File "...\ClaudeHook.ps1"
  ```

  Expected: `ClaudeAlertCount=2`, `ClaudePermissionCount=1`, `ClaudeIdleCount=1`, `ClaudeAlertType=permission`, `ClaudeAlertText=1 needs permission, 1 awaiting input`

  **Result: PASS** — Output matches expected.

- [x] **T4 — Test UserPromptSubmit clears the session**

  ```powershell
  '{"session_id":"test-001","hook_event_name":"UserPromptSubmit","cwd":"C:/some/project"}' |
      powershell.exe -ExecutionPolicy Bypass -NoProfile -File "...\ClaudeHook.ps1"
  ```

  Expected: `test-001` removed from `claude-sessions.json`, counts updated accordingly.

  **Result: PASS** — Session removed, count=1, perm=1, idle=0, type=permission.

- [x] **T5 — Test SessionEnd removes the session**

  ```powershell
  '{"session_id":"test-002","hook_event_name":"SessionEnd","cwd":"C:/other/project"}' |
      powershell.exe -ExecutionPolicy Bypass -NoProfile -File "...\ClaudeHook.ps1"
  ```

  Expected: `claude-sessions.json` has empty `sessions` object, `ClaudeAlertCount=0`, `ClaudeAlertType=none`.

  **Result: PASS** — Sessions empty, all counts zero.

- [ ] **T6 — Test Rainmeter banner display manually**

  With Rainmeter running and the ClaudeUsage skin loaded, manually edit `claude-status.inc` to set `ClaudeAlertCount=1`, `ClaudeAlertType=idle`, `ClaudeAlertText=1 session awaiting input`. Then right-click the widget and select "Refresh Skin". Verify:
  - The alert banner appears below the subtitle.
  - The banner background is amber colored.
  - The warning icon (⚠) is visible.
  - The text matches the `ClaudeAlertText` value.
  - The background rectangle extends to cover the additional height.

- [ ] **T7 — Test permission alert color**

  Edit `claude-status.inc` to set `ClaudeAlertType=permission`. Refresh the skin. Verify the banner changes from amber to red.

- [ ] **T8 — Test alert clears correctly**

  Edit `claude-status.inc` back to `ClaudeAlertCount=0`. Refresh the skin. Verify:
  - The alert banner disappears.
  - The 5-Hour Window section appears at the correct Y position (no orphan gap).
  - The background rectangle returns to normal height.

- [x] **T9 — Verify `settings.json` is valid JSON**

  After editing `~/.claude/settings.json` (task 5.1), validate it:
  ```powershell
  Get-Content "$env:USERPROFILE\.claude\settings.json" -Raw | ConvertFrom-Json
  ```
  This should parse without errors. If it throws, there is a JSON syntax error.

  **Result: PASS** — JSON valid. enabledPlugins (3 entries), autoUpdatesChannel=latest, hooks keys: Notification, UserPromptSubmit, SessionEnd.

- [ ] **T10 — End-to-end test with a real Claude session**

  1. Open a new Claude Code terminal in any directory.
  2. Let Claude finish a response and become idle (waiting for next prompt).
  3. Verify the widget shows the alert banner (may take a moment for the hook to fire).
  4. Type a new prompt and press Enter.
  5. Verify the alert banner disappears.
  6. Close the Claude terminal entirely.
  7. Verify the alert remains cleared and the session is removed from `claude-sessions.json`.

- [x] **T11 — Test stale session purge**

  Manually add a session to `claude-sessions.json` with a `since` timestamp more than 6 hours in the past:
  ```json
  {
    "sessions": {
      "stale-test": { "state": "idle", "cwd": "C:/test", "since": "2000-01-01T00:00:00" }
    }
  }
  ```
  Then fire any hook event. Verify `stale-test` is removed from the sessions file and does not contribute to the alert count.

  **Result: PASS** — stale-test purged, fresh-session tracked, count=1.

- [ ] **T12 — Test concurrent hook firing (race condition)**

  Open two Claude terminals simultaneously. Let both become idle at the same time (or simulate by running two hook invocations in quick succession). Verify both sessions are tracked correctly in `claude-sessions.json` and the count shows 2.

- [x] **T13 — Verify log output**

  Check `@Resources/usage-log.txt` after running several hook events. Verify:
  - Each hook invocation is logged with a timestamp.
  - Session add/remove events are logged.
  - No unhandled exception messages appear.
  - Log entries from `GetUsage.ps1` and `ClaudeHook.ps1` are interleaved correctly (they share the same file).

  **Result: PASS** — Log shows timestamped entries with `[Hook]` prefix, interleaved with GetUsage.ps1 entries. Add/remove/purge events all logged correctly.

- [ ] **T14 — Test with Rainmeter not running**

  Run the hook script when Rainmeter is not open. Verify the script:
  - Does not throw an unhandled exception.
  - Logs a warning about Rainmeter not being found (or handles the case gracefully).
  - Still writes `claude-status.inc` and `claude-sessions.json` correctly.
