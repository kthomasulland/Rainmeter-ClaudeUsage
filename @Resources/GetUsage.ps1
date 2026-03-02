# GetUsage.ps1 - Fetches Claude Code usage data from the API
# Writes output to a file that Rainmeter can parse

$OutputFile = "$PSScriptRoot\usage-data.inc"
$LogFile = "$PSScriptRoot\usage-log.txt"
$CredentialsPath = "$env:USERPROFILE\.claude\.credentials.json"

function Write-Log {
    param($Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] $Message"
    # Append to log file (keeps last ~50 entries naturally as file grows)
    Add-Content -Path $LogFile -Value $logEntry -Encoding UTF8
}

function Write-UsageData {
    param($Data)
    # Write without BOM for Rainmeter compatibility
    [System.IO.File]::WriteAllLines($OutputFile, $Data, [System.Text.UTF8Encoding]::new($false))
}

try {
    Write-Log "Starting usage fetch..."

    # Read credentials file
    if (-not (Test-Path $CredentialsPath)) {
        Write-Log "ERROR: Credentials file not found at $CredentialsPath"
        Write-UsageData @(
            "[Variables]",
            "FiveHourUtil=0",
            "FiveHourHrs=0",
            "FiveHourMins=0",
            "SevenDayUtil=0",
            "SevenDayDays=0",
            "SevenDayHrs=0",
            "UsageError=Credentials not found",
            "LastUpdate=Error"
        )
        exit 1
    }

    Write-Log "Reading credentials from $CredentialsPath"
    $credentials = Get-Content $CredentialsPath -Raw | ConvertFrom-Json
    $accessToken = $credentials.claudeAiOauth.accessToken
    $refreshToken = $credentials.claudeAiOauth.refreshToken
    $expiresAt = $credentials.claudeAiOauth.expiresAt

    if (-not $accessToken) {
        Write-Log "ERROR: No accessToken found in credentials file"
        Write-UsageData @(
            "[Variables]",
            "FiveHourUtil=0",
            "FiveHourHrs=0",
            "FiveHourMins=0",
            "SevenDayUtil=0",
            "SevenDayDays=0",
            "SevenDayHrs=0",
            "UsageError=No access token",
            "LastUpdate=Error"
        )
        exit 1
    }

    # Function to refresh the token
    function Refresh-Token {
        Write-Log "Attempting token refresh..."

        # OAuth 2.0 requires form-urlencoded, not JSON
        $refreshBody = "grant_type=refresh_token&refresh_token=$([uri]::EscapeDataString($refreshToken))&client_id=9d1c250a-e61b-44b0-b9e8-6db1ca8e5c85"

        $refreshResponse = Invoke-RestMethod -Uri "https://api.anthropic.com/oauth/token" `
            -Method Post `
            -ContentType "application/x-www-form-urlencoded" `
            -Body $refreshBody

        # Update credentials file with new token
        $script:credentials.claudeAiOauth.accessToken = $refreshResponse.access_token
        if ($refreshResponse.refresh_token) {
            $script:credentials.claudeAiOauth.refreshToken = $refreshResponse.refresh_token
        }
        $newExpiresAt = [DateTimeOffset]::Now.ToUnixTimeMilliseconds() + ($refreshResponse.expires_in * 1000)
        $script:credentials.claudeAiOauth.expiresAt = $newExpiresAt

        $script:credentials | ConvertTo-Json -Depth 10 | Set-Content $CredentialsPath -Encoding UTF8
        Write-Log "Token refreshed successfully, new expiry: $([DateTimeOffset]::FromUnixTimeMilliseconds($newExpiresAt).LocalDateTime)"

        return $refreshResponse.access_token
    }

    # Function to call the usage API
    function Get-Usage {
        param($Token)
        $headers = @{
            "Authorization" = "Bearer $Token"
            "anthropic-beta" = "oauth-2025-04-20"
            "User-Agent" = "claude-code/2.0.31"
            "Accept" = "application/json"
        }
        return Invoke-RestMethod -Uri "https://api.anthropic.com/api/oauth/usage" -Headers $headers -Method Get
    }

    # Call the usage API (with retry on 401)
    Write-Log "Calling usage API with token ending in ...$(($accessToken).Substring($accessToken.Length - 8))"

    $response = $null
    try {
        $response = Get-Usage -Token $accessToken
        Write-Log "API call successful"
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        Write-Log "API call failed with status $statusCode : $($_.Exception.Message)"

        if ($statusCode -eq 401 -and $refreshToken) {
            Write-Log "Got 401, attempting token refresh and retry..."
            try {
                $accessToken = Refresh-Token
                $response = Get-Usage -Token $accessToken
                Write-Log "Retry successful after token refresh"
            } catch {
                $refreshStatus = $_.Exception.Response.StatusCode.value__
                Write-Log "Refresh failed with status $refreshStatus"
                throw "Retry after refresh failed: $($_.Exception.Message)"
            }
        } else {
            throw
        }
    }

    # Helper to parse various datetime formats
    function Parse-ResetTime {
        param($TimeValue)
        if ($null -eq $TimeValue) { return $null }

        # If it's already a DateTime, return it
        if ($TimeValue -is [DateTime]) { return $TimeValue.ToLocalTime() }

        # If it's a number (Unix timestamp in seconds or milliseconds)
        if ($TimeValue -is [long] -or $TimeValue -is [int] -or $TimeValue -match '^\d+$') {
            $ts = [long]$TimeValue
            # If > year 2100 in seconds, it's probably milliseconds
            if ($ts -gt 4102444800) {
                return [DateTimeOffset]::FromUnixTimeMilliseconds($ts).LocalDateTime
            } else {
                return [DateTimeOffset]::FromUnixTimeSeconds($ts).LocalDateTime
            }
        }

        # Try ISO 8601 / standard string parsing
        try {
            # Use DateTimeOffset for ISO 8601 with timezone
            $dto = [DateTimeOffset]::Parse($TimeValue)
            return $dto.LocalDateTime
        } catch {
            # Fallback to DateTime
            try {
                return [DateTime]::Parse($TimeValue).ToLocalTime()
            } catch { }
        }

        Write-Log "WARNING: Could not parse time value: $TimeValue (type: $($TimeValue.GetType().Name))"
        return $null
    }

    # Parse 5-hour window (utilization is already a percentage 0-100)
    $fiveHourUtil = [math]::Round($response.five_hour.utilization, 1)
    Write-Log "5hr resets_at raw value: $($response.five_hour.resets_at) (type: $($response.five_hour.resets_at.GetType().Name))"
    $fiveHourReset = Parse-ResetTime $response.five_hour.resets_at
    $fiveHourHrs = 0
    $fiveHourMins = 0
    if ($fiveHourReset) {
        $fiveHourRemaining = $fiveHourReset - (Get-Date)
        $fiveHourTotalMins = [math]::Max(0, [math]::Floor($fiveHourRemaining.TotalMinutes))
        $fiveHourHrs = [math]::Floor($fiveHourTotalMins / 60)
        $fiveHourMins = $fiveHourTotalMins % 60
    }

    # Parse 7-day window
    $sevenDayUtil = 0
    $sevenDayDays = 0
    $sevenDayHrs = 0

    if ($response.seven_day -and $null -ne $response.seven_day.utilization) {
        $sevenDayUtil = [math]::Round($response.seven_day.utilization, 1)
        if ($response.seven_day.resets_at) {
            Write-Log "7day resets_at raw value: $($response.seven_day.resets_at) (type: $($response.seven_day.resets_at.GetType().Name))"
            $sevenDayReset = Parse-ResetTime $response.seven_day.resets_at
            if ($sevenDayReset) {
                $sevenDayRemaining = $sevenDayReset - (Get-Date)
                $sevenDayTotalMins = [math]::Max(0, [math]::Floor($sevenDayRemaining.TotalMinutes))
                $sevenDayDays = [math]::Floor($sevenDayTotalMins / 1440)
                $sevenDayHrs = [math]::Floor(($sevenDayTotalMins % 1440) / 60)
            }
        }
    }

    $lastUpdate = Get-Date -Format "h:mm tt"

    Write-UsageData @(
        "[Variables]",
        "FiveHourUtil=$fiveHourUtil",
        "FiveHourHrs=$fiveHourHrs",
        "FiveHourMins=$fiveHourMins",
        "SevenDayUtil=$sevenDayUtil",
        "SevenDayDays=$sevenDayDays",
        "SevenDayHrs=$sevenDayHrs",
        "UsageError=None",
        "LastUpdate=$lastUpdate"
    )
    Write-Log "SUCCESS: 5hr=$fiveHourUtil%, 7day=$sevenDayUtil%"

} catch {
    $fullError = $_.Exception.Message
    Write-Log "ERROR: $fullError"
    $errorMsg = ($fullError -replace '["\r\n]', ' ').Substring(0, [Math]::Min(50, $fullError.Length))
    Write-UsageData @(
        "[Variables]",
        "FiveHourUtil=0",
        "FiveHourHrs=0",
        "FiveHourMins=0",
        "SevenDayUtil=0",
        "SevenDayDays=0",
        "SevenDayHrs=0",
        "UsageError=$errorMsg",
        "LastUpdate=Error"
    )
}
