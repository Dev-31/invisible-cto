# logger.ps1 - Centralized logging for Invisible CTO

param(
    [string]$LogDir = "$PSScriptRoot\..\logs",
    [switch]$NoEcho
)

$LogFile = Join-Path $LogDir "invisible_cto_$(Get-Date -Format 'yyyy-MM-dd').log"

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "DEBUG", "HEAL", "MONITOR")]
        [string]$Level = "INFO"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = if ($Level -eq "INFO") { "White" }
             elseif ($Level -eq "WARN") { "Yellow" }
             elseif ($Level -eq "ERROR") { "Red" }
             elseif ($Level -eq "DEBUG") { "Gray" }
             elseif ($Level -eq "HEAL") { "Cyan" }
             elseif ($Level -eq "MONITOR") { "Green" }
             else { "White" }
    
    $entry = "[$timestamp] [$Level] $Message"
    
    if (-not (Test-Path $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }
    
    Add-Content -Path $LogFile -Value $entry -Encoding UTF8
    Write-Host $entry -ForegroundColor $color
}

function Get-LogReader {
    param([int]$Lines = 50)
    if (Test-Path $LogFile) {
        Get-Content $LogFile -Tail $Lines -Encoding UTF8
    }
}

Set-Alias -Name log -Value Write-Log -Scope Global -ErrorAction SilentlyContinue
Set-Alias -Name logread -Value Get-LogReader -Scope Global -ErrorAction SilentlyContinue

Write-Log "Logger initialized. Log file: $LogFile" "INFO"
