# monitor.ps1 - Railway Log Monitor with Error Detection (PS 5.1 compatible)
# Phase 2: Log Monitoring Loop - Verified against Railway CLI 2026-03-24

param(
    [string]$ServiceName  = $env:RAILWAY_SERVICE_NAME,
    [string]$Environment  = "production",
    [int]$WatchMinutes    = 0,
    [int]$PollMs          = 5000,
    [string]$Token,
    [switch]$TestMode,
    [switch]$Verbose
)

$ErrorActionPreference = "Continue"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir

. "$ScriptDir\logger.ps1"
Write-Log "=== Invisible CTO Monitor Started ===" "INFO"
Write-Log "Service: $ServiceName | Env: $Environment | Poll: ${PollMs}ms" "INFO"

. "$ScriptDir\railway_wrapper.ps1"

# Crash patterns - verified against Railway real log output
$CrashPatterns = @(
    @{ Pattern = "Traceback \(most recent call last\)";                         Reason = "Python exception";             Severity = "FATAL" },
    @{ Pattern = "Error:|Exception:|TypeError:|ValueError:|AttributeError:";   Reason = "Python error";                 Severity = "FATAL" },
    @{ Pattern = "ECONNREFUSED";                                                Reason = "Connection refused";            Severity = "FATAL" },
    @{ Pattern = "EADDRINUSE|Port \d+ already in use";                           Reason = "Port conflict";               Severity = "FATAL" },
    @{ Pattern = "500 Internal Server Error";                                     Reason = "Server 500 error";             Severity = "FATAL" },
    @{ Pattern = "502 Bad Gateway|503 Service Unavailable|504 Gateway Timeout";  Reason = "Gateway error";               Severity = "FATAL" },
    @{ Pattern = "SQLite error|sqlite3\.OperationalError";                       Reason = "SQLite error";                 Severity = "FATAL" },
    @{ Pattern = "psycopg2|postgresql.*error|ECONNREFUSED.*5432";               Reason = "Postgres error";               Severity = "FATAL" },
    @{ Pattern = "out of memory|OOM|heap out of memory";                          Reason = "Memory exhaustion";            Severity = "FATAL" },
    @{ Pattern = "SIGKILL|SIGTERM|Segmentation fault";                           Reason = "Process killed";               Severity = "FATAL" },
    @{ Pattern = "ModuleNotFoundError|ImportError:.*cannot import";               Reason = "Missing module";               Severity = "FATAL" },
    @{ Pattern = "Environment variable.*not set|KeyError:.*env";                 Reason = "Missing env var";              Severity = "FATAL" },
    @{ Pattern = "429.*Too Many Requests|rate_limit|Quota exceeded";            Reason = "Rate/Quota exceeded";          Severity = "WARN" },
    @{ Pattern = "timeout|timed out";                                            Reason = "Operation timeout";            Severity = "WARN" }
)

$WarningPatterns = @(
    @{ Pattern = "DeprecationWarning|deprecated";      Reason = "Deprecated feature";   Severity = "WARN" },
    @{ Pattern = "Retrying|retry attempt|backing off"; Reason = "Transient failure";     Severity = "WARN" },
    @{ Pattern = "Slow query|query timeout";            Reason = "Slow DB query";         Severity = "WARN" }
)

# False positives - these come tagged as ERROR level but are NOT crashes
$FalsePositivePatterns = @(
    "INFO:     Started server process",
    "INFO:     Waiting for application startup",
    "INFO:     Application startup complete",
    "INFO:     Uvicorn running on",
    "FastAPIDeprecationWarning",
    "DeprecationWarning",
    "regex.*deprecated.*pattern"
)

# State
$script:CrashCount = 0
$script:CrashLog = @()
$script:Seen = @{}
$script:SessionId = Get-Date -Format "yyyyMMdd-HHmmss"
$script:StartTime = Get-Date

function Write-Incident {
    param([hashtable]$Incident)
    $file = Join-Path $ProjectRoot "logs\crash_incidents_$($script:SessionId).json"
    $script:CrashLog += $Incident
    $script:CrashLog | ConvertTo-Json -Depth 5 | Set-Content $file -Encoding UTF8
}

function Test-IsRealCrash {
    param([string]$Message)
    foreach ($fp in $FalsePositivePatterns) {
        if ($Message -match $fp) { return $false }
    }
    return $true
}

function Invoke-Classify {
    param([PSCustomObject]$Entry)
    $msg = $Entry.Message
    if (-not $msg) { return $null }
    
    foreach ($p in $CrashPatterns) {
        if ($msg -match $p.Pattern) {
            return @{ Matched = $true; Reason = $p.Reason; Severity = $p.Severity; Pattern = $p.Pattern; Raw = $Entry.Raw }
        }
    }
    foreach ($p in $WarningPatterns) {
        if ($msg -match $p.Pattern) {
            return @{ Matched = $true; Reason = $p.Reason; Severity = "WARN"; Pattern = $p.Pattern; Raw = $Entry.Raw }
        }
    }
    return $null
}

if ($TestMode) {
    Write-Log "TEST MODE: Simulated crash stream" "WARN"
}

function Start-Monitor {
    $iter = 0
    
    while ($true) {
        $iter++
        
        if ($WatchMinutes -gt 0 -and ((Get-Date) - $script:StartTime).TotalMinutes -ge $WatchMinutes) {
            Write-Log "Watch time ($WatchMinutes min) reached. Stopping." "INFO"
            break
        }
        
        # Test mode: inject a crash after first iteration
        if ($TestMode -and $iter -eq 2) {
            Start-Sleep 5
            $testMsg = "Error: Cannot find module './routes/api' - ModuleNotFoundError"
            $testEntry = [PSCustomObject]@{
                Timestamp = (Get-Date).ToString("o")
                Level     = "error"
                Message   = $testMsg
                Raw       = @{ timestamp = (Get-Date).ToString("o"); level = "error"; message = $testMsg }
            }
            
            $classified = Invoke-Classify -Entry $testEntry
            if ($classified) {
                $script:CrashCount++
                $incident = @{
                    Id         = "TEST_$($script:CrashCount)"
                    Reason     = $classified.Reason
                    Pattern    = $classified.Pattern
                    Severity   = "FATAL"
                    Timestamp  = (Get-Date).ToString("o")
                    IsTest     = $true
                }
                Write-Incident -Incident $incident
                Write-Log "CRASH #$($script:CrashCount): $($classified.Reason)" "ERROR"
                
                @{
                    IncidentId = $incident.Id
                    Reason     = $incident.Reason
                    Timestamp  = $incident.Timestamp
                    RawLine    = $testMsg
                } | ConvertTo-Json | Set-Content (Join-Path $ProjectRoot "logs\heal_queue.json") -Encoding UTF8
                
                Write-Log "heal_queue.json written - heal.ps1 will pick this up" "HEAL"
            }
        }
        
        # Real Railway fetch
        if (-not $TestMode) {
            $result = Get-RailwayLogs -Lines 50
            if (-not $result.Success) {
                Start-Sleep -Milliseconds $PollMs
                continue
            }
            
            foreach ($rawEntry in $result.Parsed) {
                $msg = if ($rawEntry.message) { $rawEntry.message } else { "" }
                $hash = $msg.GetHashCode()
                if ($script:Seen.ContainsKey($hash)) { continue }
                $script:Seen[$hash] = $true
                if ($script:Seen.Count -gt 500) {
                    $trim = $script:Seen.Count - 250
                    $keys = $script:Seen.Keys | Select-Object -First $trim
                    foreach ($k in $keys) { $script:Seen.Remove($k) }
                }
                
                $entry = [PSCustomObject]@{
                    Timestamp = if ($rawEntry.timestamp) { $rawEntry.timestamp } else { (Get-Date).ToString("o") }
                    Level     = if ($rawEntry.level) { $rawEntry.level } else { "info" }
                    Message   = $msg
                    Event     = if ($rawEntry.event) { $rawEntry.event } else { $null }
                    Raw       = $rawEntry
                }
                
                if ($Verbose) {
                    $lvl = $entry.Level
                    Write-Host "[$lvl] $($entry.Message)" -ForegroundColor DarkGray
                }
                
                $classified = Invoke-Classify -Entry $entry
                if (-not $classified) { continue }
                
                # Skip false positives (Railway level field lies)
                if ($entry.Level -eq "error" -and -not (Test-IsRealCrash -Message $entry.Message)) {
                    continue
                }
                
                if ($classified.Severity -eq "FATAL") {
                    $script:CrashCount++
                    $incident = @{
                        Id         = "CRASH_$($script:SessionId)_$($script:CrashCount)"
                        Reason     = $classified.Reason
                        Pattern    = $classified.Pattern
                        Severity   = "FATAL"
                        Timestamp  = (Get-Date).ToString("o")
                        RawMessage = $entry.Message
                    }
                    Write-Incident -Incident $incident
                    Write-Log "CRASH #$($script:CrashCount): $($classified.Reason)" "ERROR"
                    Write-Log "  Line: $($entry.Message)" "DEBUG"
                    
                    @{
                        IncidentId = $incident.Id
                        Reason     = $incident.Reason
                        Timestamp  = $incident.Timestamp
                        RawLine    = $entry.Message
                    } | ConvertTo-Json | Set-Content (Join-Path $ProjectRoot "logs\heal_queue.json") -Encoding UTF8
                    
                    Write-Log "heal_queue.json written" "HEAL"
                }
                else {
                    Write-Log "WARN: $($classified.Reason)" "WARN"
                }
            }
        }
        
        if (-not $TestMode) {
            Start-Sleep -Milliseconds $PollMs
        }
    }
}

Start-Monitor

Write-Log "=== Monitor Ended ===" "INFO"
Write-Log "Total crashes: $($script:CrashCount)" "INFO"
