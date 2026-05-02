# ClaudeHook.ps1 - Claude Code hook handler
# Receives JSON on stdin from Claude Code's hooks system
# Updates claude-status.inc and triggers Rainmeter refresh
# Use -Dismiss switch to clear all alerts (called from Rainmeter click action)

param(
    [switch]$Dismiss
)

$SessionsFile = "$PSScriptRoot\claude-sessions.json"
$StatusFile   = "$PSScriptRoot\claude-status.inc"
$LogFile      = "$PSScriptRoot\usage-log.txt"

function Write-Log {
    param($Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [Hook] $Message"
    # Append to log file (shared with GetUsage.ps1 for unified debugging)
    Add-Content -Path $LogFile -Value $logEntry -Encoding UTF8
}

function Write-StatusData {
    param($Data)
    # Write without BOM for Rainmeter compatibility
    [System.IO.File]::WriteAllLines($StatusFile, $Data, [System.Text.UTF8Encoding]::new($false))
}

try {
    # --- Dismiss mode: clear all alerts (triggered by clicking the alert banner) ---
    if ($Dismiss) {
        Write-Log "Dismiss requested - clearing all sessions"
        Write-StatusData @(
            "[Variables]",
            "ClaudeAlertCount=0",
            "ClaudeBannerCount=0",
            "ClaudePermissionCount=0",
            "ClaudeIdleCount=0",
            "ClaudeWorkingCount=0",
            "ClaudeAlertType=none",
            "ClaudeAlertText=All sessions clear"
        )
        [System.IO.File]::WriteAllText($SessionsFile, '{"sessions":{}}', [System.Text.UTF8Encoding]::new($false))
        $rainmeterExe = "C:\Program Files\Rainmeter\Rainmeter.exe"
        if (Test-Path $rainmeterExe) {
            & $rainmeterExe "!Refresh" "ClaudeUsage" "ClaudeUsage"
        }
        exit 0
    }

    # --- 1.2: Parse hook event JSON from stdin ---
    $inputJson = $input | Out-String
    $event = $inputJson | ConvertFrom-Json

    $sessionId   = $event.session_id
    $hookEvent   = $event.hook_event_name
    $notifType   = $event.notification_type   # null for non-Notification events
    $cwd         = $event.cwd

    # Log full JSON payload for field discovery (temporary diagnostic)
    Write-Log "RAW JSON: $($inputJson.Trim())"
    Write-Log "Hook received: event=$hookEvent, notifType=$notifType, session=$sessionId"

    # --- 1.3: Load claude-sessions.json with file-lock retry ---
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

    if ($null -eq $sessions -or $null -eq $sessions.sessions) {
        $sessions = [PSCustomObject]@{ sessions = @{} }
    }

    # Convert .sessions to a regular hashtable for easy add/remove
    $sessionMap = @{}
    $sessions.sessions.PSObject.Properties | ForEach-Object { $sessionMap[$_.Name] = $_.Value }

    # --- 1.4: Handle Notification event (add/update session) ---
    if ($hookEvent -eq "Notification") {
        if ($notifType -eq "permission_prompt") {
            $state = "permission"
        } elseif ($notifType -eq "idle_prompt") {
            $state = "idle"
        } else {
            Write-Log "Skipping unknown notification_type: $notifType"
            $state = $null
        }

        if ($null -ne $state) {
            $sessionMap[$sessionId] = [PSCustomObject]@{
                state = $state
                cwd   = $cwd
                since = (Get-Date -Format "o")   # ISO 8601 round-trip format
            }
            Write-Log "Added/updated session $sessionId as state=$state"
        }
    }
    # --- 1.5a: UserPromptSubmit -> mark session as working (Claude is processing) ---
    elseif ($hookEvent -eq "UserPromptSubmit") {
        $sessionMap[$sessionId] = [PSCustomObject]@{
            state = "working"
            cwd   = $cwd
            since = (Get-Date -Format "o")
        }
        Write-Log "Marked session $sessionId as state=working"
    }
    # --- 1.5b: Stop / SessionEnd -> remove session (turn finished or session closed) ---
    elseif ($hookEvent -eq "Stop" -or $hookEvent -eq "SessionEnd") {
        if ($sessionMap.ContainsKey($sessionId)) {
            $sessionMap.Remove($sessionId)
            Write-Log "Removed session $sessionId (event: $hookEvent)"
        }
    }

    # --- 1.6: Purge stale sessions older than 6 hours ---
    $cutoff = (Get-Date).AddHours(-6)
    $staleKeys = @($sessionMap.Keys | Where-Object {
        $entry = $sessionMap[$_]
        try { [DateTime]::Parse($entry.since) -lt $cutoff } catch { $true }
    })
    $staleKeys | ForEach-Object {
        Write-Log "Purging stale session: $_"
        $sessionMap.Remove($_)
    }

    # --- 1.7: Save updated sessions back to claude-sessions.json ---
    # Convert hashtable to PSCustomObject so ConvertTo-Json serializes key/value pairs
    # (not the Hashtable .NET object properties like Count, Keys, Values, etc.)
    $sessionObj = New-Object PSObject
    $sessionMap.Keys | ForEach-Object { $sessionObj | Add-Member -MemberType NoteProperty -Name $_ -Value $sessionMap[$_] }
    $outputObj = [PSCustomObject]@{ sessions = $sessionObj }
    $json = $outputObj | ConvertTo-Json -Depth 5
    $writeRetries = 5
    while ($writeRetries -gt 0) {
        try {
            [System.IO.File]::WriteAllText($SessionsFile, $json, [System.Text.UTF8Encoding]::new($false))
            break
        } catch {
            $writeRetries--
            if ($writeRetries -eq 0) { throw }
            Start-Sleep -Milliseconds 100
        }
    }

    # --- 1.8: Compute summary variables ---
    $permCount    = ($sessionMap.Values | Where-Object { $_.state -eq "permission" } | Measure-Object).Count
    $idleCount    = ($sessionMap.Values | Where-Object { $_.state -eq "idle" }       | Measure-Object).Count
    $workingCount = ($sessionMap.Values | Where-Object { $_.state -eq "working" }    | Measure-Object).Count
    # AlertCount = needs-user-attention only (drives sound + pulse). BannerCount also includes working.
    $alertCount  = $permCount + $idleCount
    $bannerCount = $alertCount + $workingCount

    # Determine display type (permission > idle > working > none)
    if     ($permCount    -gt 0) { $alertType = "permission" }
    elseif ($idleCount    -gt 0) { $alertType = "idle" }
    elseif ($workingCount -gt 0) { $alertType = "working" }
    else                          { $alertType = "none" }

    # Build human-readable banner text (priority matches alertType)
    if ($alertType -eq "none") {
        $alertText = "All sessions clear"
    } elseif ($permCount -gt 0 -and $idleCount -gt 0) {
        $alertText = "$permCount needs permission, $idleCount awaiting input"
    } elseif ($permCount -gt 0) {
        if ($permCount -eq 1) { $alertText = "1 session needs permission" }
        else                   { $alertText = "$permCount sessions need permission" }
    } elseif ($idleCount -gt 0) {
        $s = if ($idleCount -eq 1) { "session" } else { "sessions" }
        $alertText = "$idleCount $s awaiting input"
    } else {
        $s = if ($workingCount -eq 1) { "session" } else { "sessions" }
        $alertText = "Working... ($workingCount $s)"
    }

    Write-Log "Summary: banner=$bannerCount, perm=$permCount, idle=$idleCount, working=$workingCount, type=$alertType"

    # --- 1.9: Write claude-status.inc ---
    Write-StatusData @(
        "[Variables]",
        "ClaudeAlertCount=$alertCount",
        "ClaudeBannerCount=$bannerCount",
        "ClaudePermissionCount=$permCount",
        "ClaudeIdleCount=$idleCount",
        "ClaudeWorkingCount=$workingCount",
        "ClaudeAlertType=$alertType",
        "ClaudeAlertText=$alertText"
    )

    # --- 1.10: Trigger Rainmeter refresh ---
    $rainmeterExe = "C:\Program Files\Rainmeter\Rainmeter.exe"
    if (Test-Path $rainmeterExe) {
        & $rainmeterExe "!Refresh" "ClaudeUsage" "ClaudeUsage"
        Write-Log "Triggered Rainmeter refresh"
    } else {
        Write-Log "WARNING: Rainmeter.exe not found at expected path"
    }

} catch {
    # 1.11: Never crash visibly - log and exit cleanly
    Write-Log "ERROR: $($_.Exception.Message)"
}
