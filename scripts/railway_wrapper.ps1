# railway_wrapper.ps1 - Railway CLI wrapper (PowerShell 5.1 compatible)
# Verified against Railway CLI 2026-03-24

param(
    [string]$Token,
    [string]$ProjectId,
    [string]$ServiceName,
    [string]$Environment
)

$ErrorActionPreference = "Continue"

if (-not $Token) { $Token = $env:RAILWAY_TOKEN }
if (-not $ProjectId) { $ProjectId = $env:RAILWAY_PROJECT_ID }
if (-not $ServiceName) { $ServiceName = $env:RAILWAY_SERVICE_NAME }
if (-not $Environment) { $Environment = $env:RAILWAY_ENVIRONMENT }

if (-not $Token) {
    Write-Warning "[RailwayWrapper] No Railway token - set `$env:RAILWAY_TOKEN"
}
$env:RAILWAY_TOKEN = $Token

function Invoke-RailwayCLI {
    param(
        [Parameter(Mandatory)]
        [string[]]$Args,
        [int]$TimeoutSec = 60
    )
    
    $start = Get-Date
    try {
        $result = railway @Args 2>&1
        $exitCode = $LASTEXITCODE
        $elapsed = ((Get-Date) - $start).TotalSeconds
        
        return @{
            Success   = ($exitCode -eq 0)
            ExitCode  = $exitCode
            Output    = $result | Out-String
            Raw       = $result
            Elapsed   = [Math]::Round($elapsed, 2)
            Timestamp = (Get-Date).ToString("o")
        }
    }
    catch {
        return @{
            Success   = $false
            ExitCode  = -1
            Output    = $_.Exception.Message
            Raw       = $_
            Elapsed   = ((Get-Date) - $start).TotalSeconds
            Timestamp = (Get-Date).ToString("o")
            Error     = $true
        }
    }
}

function Get-RailwayArgs {
    param([string[]]$CmdArgs, [switch]$NoService)
    $args = $CmdArgs
    if ($ServiceName -and -not $NoService) { $args = @("--service", $ServiceName) + $args }
    if ($Environment) { $args = @("--environment", $Environment) + $args }
    return $args
}

function Get-RailwayLogs {
    param(
        [int]$Lines = 50,
        [string]$Since,
        [string]$Filter
    )
    
    $args = Get-RailwayArgs -CmdArgs @("logs", "--json", "--lines", $Lines)
    if ($Since)  { $args += @("--since", $Since) }
    if ($Filter) { $args += @("--filter", $Filter) }
    
    $result = Invoke-RailwayCLI -Args $args
    
    if (-not $result.Success) {
        return @{ Success = $false; Error = $result.Output; Raw = $result.Raw }
    }
    
    $parsed = @()
    foreach ($line in $result.Raw) {
        if ($line -match '^\s*\{') {
            try { $parsed += ($line | ConvertFrom-Json) } catch { }
        }
    }
    
    return @{
        Success   = $true
        Raw       = $result.Raw
        Parsed    = $parsed
        Timestamp = $result.Timestamp
    }
}

function Start-RailwayLogStream {
    param([int]$PollMs = 5000)
    
    $seen = @{}
    Write-Host "[RailwayWrapper] Starting log stream (poll every ${PollMs}ms)..." -ForegroundColor Cyan
    
    while ($true) {
        $result = Get-RailwayLogs -Lines 50
        if ($result.Success -and $result.Parsed) {
            foreach ($entry in $result.Parsed) {
                $msg = if ($entry.message) { $entry.message } else { "$entry" }
                $hash = $msg.GetHashCode()
                if (-not $seen.ContainsKey($hash)) {
                    $seen[$hash] = $true
                    if ($seen.Count -gt 500) {
                        $trim = $seen.Count - 250
                        $keys = $seen.Keys | Select-Object -First $trim
                        foreach ($k in $keys) { $seen.Remove($k) }
                    }
                    
                    [PSCustomObject]@{
                        Timestamp = if ($entry.timestamp) { $entry.timestamp } else { (Get-Date).ToString("o") }
                        Level     = if ($entry.level) { $entry.level } else { "info" }
                        Message   = $msg
                        Event     = if ($entry.event) { $entry.event } else { $null }
                        Status    = if ($entry.status_code) { $entry.status_code } else { $null }
                        Path      = if ($entry.path) { $entry.path } else { $null }
                        Logger    = if ($entry.logger) { $entry.logger } else { $null }
                        Raw       = $entry
                    }
                }
            }
        }
        Start-Sleep -Milliseconds $PollMs
    }
}

function Invoke-RailwayErrorLogs {
    param([int]$Lines = 50)
    $args = Get-RailwayArgs -CmdArgs @("logs", "--json", "--lines", $Lines, "--filter", "@level:error")
    $result = Invoke-RailwayCLI -Args $args
    if (-not $result.Success) { return @{ Success = $false; Raw = $result.Raw } }
    
    $parsed = @()
    foreach ($line in $result.Raw) {
        if ($line -match '^\s*\{') {
            try { $parsed += ($line | ConvertFrom-Json) } catch { }
        }
    }
    return @{ Success = $true; Parsed = $parsed }
}

function Invoke-RailwayDeploy {
    param([switch]$Detach = $true)
    $args = Get-RailwayArgs -CmdArgs @("up")
    if ($Detach) { $args += "--detach" }
    Write-Host "[RailwayWrapper] Triggering railway up..." -ForegroundColor Cyan
    $result = Invoke-RailwayCLI -Args $args
    if ($result.Success) { Write-Host "[RailwayWrapper] Deploy triggered" -ForegroundColor Green }
    else { Write-Warning "[RailwayWrapper] Deploy failed: $($result.Output)" }
    return $result
}

function Invoke-RailwayRedeploy {
    param([string]$DeploymentId)
    if ($DeploymentId) {
        $args = Get-RailwayArgs -CmdArgs @("deployment", "redeploy", $DeploymentId, "--detach")
    }
    else {
        $args = @("redeploy")
    }
    Write-Host "[RailwayWrapper] Redeploying..." -ForegroundColor Cyan
    return Invoke-RailwayCLI -Args $args
}

function Restart-RailwayDeployment {
    $args = Get-RailwayArgs -CmdArgs @("restart")
    Write-Host "[RailwayWrapper] Restarting..." -ForegroundColor Cyan
    return Invoke-RailwayCLI -Args $args
}

function Test-RailwayHealth {
    $whoami = Invoke-RailwayCLI -Args @("whoami")
    if ($whoami.Success -and $whoami.Output -match "\w") {
        return @{
            Healthy    = $true
            LoggedInAs = ($whoami.Output -split "`n")[0].Trim()
        }
    }
    return @{
        Healthy = $false
        Error   = $whoami.Output
        Hint    = "Run `railway login` or set `$env:RAILWAY_TOKEN"
    }
}

function Get-RailwayDeploymentStatus {
    $args = Get-RailwayArgs -CmdArgs @("deployment", "list", "--json")
    $result = Invoke-RailwayCLI -Args $args
    if (-not $result.Success) { return $result }
    
    $parsed = @()
    try {
        $parsed = $result.Raw | ForEach-Object {
            $_ | ConvertFrom-Json -ErrorAction SilentlyContinue
        } | Where-Object { $_ }
    }
    catch { }
    
    return @{ Success = $true; Deployments = $parsed; Raw = $result.Raw }
}

function Set-RailwayVariable {
    param([Parameter(Mandatory)][string]$Name, [string]$Value)
    $args = Get-RailwayArgs -CmdArgs @("variables", "set", "$Name=$Value")
    return Invoke-RailwayCLI -Args $args
}

function Get-RailwayVariables {
    $args = Get-RailwayArgs -CmdArgs @("variables", "list", "--json")
    $result = Invoke-RailwayCLI -Args $args
    if (-not $result.Success) { return $result }
    
    $parsed = @()
    try {
        $parsed = $result.Raw | ForEach-Object {
            $_ | ConvertFrom-Json -ErrorAction SilentlyContinue
        } | Where-Object { $_ }
        return @{ Success = $true; Variables = $parsed }
    }
    catch {
        return @{ Success = $true; Raw = $result.Raw }
    }
}
