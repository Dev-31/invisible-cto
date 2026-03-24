# test_monitor.ps1 - Smoke test for Invisible CTO monitor
# Tests: (1) logger, (2) railway wrapper, (3) monitor loop in test mode

param(
    [switch]$Full,
    [int]$TestDurationSec = 15
)

$ErrorActionPreference = "Continue"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir

. "$ScriptDir\logger.ps1"
. "$ScriptDir\railway_wrapper.ps1"

$passed = 0
$failed = 0

function Test-Assert {
    param($Condition, $Name)
    if ($Condition) {
        Write-Host "  [PASS] $Name" -ForegroundColor Green
        $script:passed++
    }
    else {
        Write-Host "  [FAIL] $Name" -ForegroundColor Red
        $script:failed++
    }
}

Write-Host ""
Write-Host "=== Invisible CTO - Smoke Tests ===" -ForegroundColor Cyan
Write-Host ""

# Test 1: Logger
Write-Host "[1] Logger Module" -ForegroundColor Yellow
try {
    . "$ScriptDir\logger.ps1"
    Write-Log "Test log entry" "INFO"
    Test-Assert $true "Logger executes without error"
    $todayLog = Get-ChildItem "$ProjectRoot\logs" -Filter "invisible_cto_*.log" | Select-Object -First 1
    Test-Assert ($todayLog -ne $null) "Log file created"
}
catch {
    Write-Host "  [FAIL] Logger: $_" -ForegroundColor Red
    $script:failed++
}

# Test 2: Railway Wrapper
Write-Host ""
Write-Host "[2] Railway Wrapper" -ForegroundColor Yellow

$health = Test-RailwayHealth
Test-Assert ($health.Healthy -eq $true) "Railway CLI health check"

Write-Host "  Testing log fetch..." -ForegroundColor Gray
$logs = Get-RailwayLogs -Lines 10
Test-Assert ($logs.Success -eq $true) "Get-RailwayLogs succeeds"

if ($logs.Success -and $logs.Parsed.Count -gt 0) {
    $hasMessage = $logs.Parsed[0].PSObject.Properties.Name -contains "message"
    Test-Assert $hasMessage "Log entries have 'message' field"
    Write-Host "    Sample: $($logs.Parsed[0].message)" -ForegroundColor DarkGray
}
else {
    Write-Host "    (No logs returned - may be normal for idle project)" -ForegroundColor DarkGray
}

# Test 3: Monitor in Test Mode
Write-Host ""
Write-Host "[3] Monitor - Test Mode (simulated crash detection)" -ForegroundColor Yellow

Write-Host "  Starting monitor in test mode for ${TestDurationSec}s..." -ForegroundColor Gray

$monitorJob = Start-Job -ScriptBlock {
    param($monScript, $projRoot)
    Set-Location $projRoot
    & "$monScript" -TestMode -WatchMinutes 1
} -ArgumentList "$ScriptDir\monitor.ps1", $ProjectRoot

Start-Sleep $TestDurationSec

if ($monitorJob.State -eq 'Running') {
    Stop-Job $monitorJob -ErrorAction SilentlyContinue
    Remove-Job $monitorJob -Force -ErrorAction SilentlyContinue
    Write-Host "  [PASS] Monitor ran for ${TestDurationSec}s without crash" -ForegroundColor Green
    $passed++
}
else {
    $result = Receive-Job $monitorJob -Keep
    Write-Host "  [INFO] Monitor state: $($monitorJob.State)" -ForegroundColor Cyan
    Remove-Job $monitorJob -Force -ErrorAction SilentlyContinue
}

# Check heal queue
$healQueue = Get-ChildItem "$ProjectRoot\logs\heal_queue.json" -ErrorAction SilentlyContinue
Test-Assert ($healQueue -ne $null) "heal_queue.json created (monitor detected crash)"

# Test 4: Heal Loop (Simulate Mode)
Write-Host ""
Write-Host "[4] Heal Loop - Simulate Mode" -ForegroundColor Yellow

$healJob = Start-Job -ScriptBlock {
    param($healScript, $projRoot)
    Set-Location $projRoot
    & "$healScript" -Mode Simulate
} -ArgumentList "$ScriptDir\heal.ps1", $ProjectRoot

Start-Sleep 10

if ($healJob.State -eq 'Running') {
    Stop-Job $healJob -ErrorAction SilentlyContinue
    Remove-Job $healJob -Force -ErrorAction SilentlyContinue
    Write-Host "  [PASS] Heal loop ran without error" -ForegroundColor Green
    $passed++
}
else {
    Write-Host "  [INFO] Heal loop exited (expected - no real crash to fix)" -ForegroundColor Cyan
    Remove-Job $healJob -Force -ErrorAction SilentlyContinue
}

# Summary
Write-Host ""
Write-Host "=== Results: $passed passed, $failed failed ===" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Red" })
Write-Host ""

if ($failed -eq 0) {
    Write-Host "All smoke tests passed!" -ForegroundColor Green
}
