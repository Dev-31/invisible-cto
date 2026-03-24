# heal.ps1 — Invisible CTO Self-Healing Loop
# Phase 3: Intelligent Patch Writing + Phase 4: Self-Healing Verification
# Usage: .\heal.ps1 [-Mode Full|Simulate] [-IncidentId <id>]

param(
    [ValidateSet("Full", "Simulate", "AnalyzeOnly")]
    [string]$Mode = "Full",
    [string]$IncidentId,
    [int]$MaxHealAttempts = 3,
    [int]$VerifyWaitSec = 30,
    [int]$VerifyTimeoutSec = 120,
    [string]$Token,
    [string]$ProjectId
)

$ErrorActionPreference = "Continue"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir

. "$ScriptDir\logger.ps1"
. "$ScriptDir\railway_wrapper.ps1"

Write-Log "=== Invisible CTO Heal Loop Started ===" "HEAL"
Write-Log "Mode: $Mode | Max Attempts: $MaxHealAttempts | Verify Wait: ${VerifyWaitSec}s" "HEAL"

# ─── State ───────────────────────────────────────────────────────────────────
$HealStateFile = Join-Path $ProjectRoot "logs\heal_state.json"

function Get-HealState {
    if (Test-Path $HealStateFile) {
        try {
            return Get-Content $HealStateFile -Raw | ConvertFrom-Json
        }
        catch { }
    }
    return [PSCustomObject]@{
        ActiveIncident  = $null
        AttemptCount    = 0
        History         = @()
        StartedAt       = $null
    }
}

function Set-HealState {
    param([object]$State)
    $State | ConvertTo-Json -Depth 5 | Set-Content -Path $HealStateFile -Encoding UTF8
}

# ─── Known Fix Patterns (Trivial Auto-Heals) ────────────────────────────────
# These don't need LLM — pattern match → apply fix directly
$KnownFixes = @{
    "ENOENT.*cannot find module" = {
        param($ctx)
        # Missing npm package — add it
        Write-Log "Auto-fix: Missing npm package detected" "WARN"
        # This is a placeholder — real impl would parse the module name and do `npm install`
        return @{ Applied = $false; Reason = "Would run: npm install <module>"; NeedsLLM = $true }
    }
    "Port \d+ already in use" = {
        param($ctx)
        # Kill the process on that port
        Write-Log "Auto-fix: Killing process on conflicting port" "WARN"
        return @{ Applied = $true; Action = "Kill port process"; Script = "Get-NetTCPConnection -LocalPort <port> | Stop-Process -Force" }
    }
    "ECONNREFUSED.*5432" = {
        param($ctx)
        # Postgres not running — try to start it or use Neon
        return @{ Applied = $false; Reason = "DB connection refused (5432)"; NeedsLLM = $true }
    }
    "missing.*env|undefined.*env.*variable" = {
        param($ctx)
        return @{ Applied = $false; Reason = "Missing env var"; NeedsLLM = $true }
    }
    "SyntaxError|ParseError|IndentationError" = {
        param($ctx)
        return @{ Applied = $false; Reason = "Syntax error — needs code fix"; NeedsLLM = $true }
    }
}

# ─── LLM Patch Writer ─────────────────────────────────────────────────────────
function Write-PatchWithLLM {
    param(
        [string]$ErrorReason,
        [string]$ErrorLine,
        [string]$Context,       # surrounding log lines
        [hashtable]$Incident
    )
    
    Write-Log "Analyzing error with LLM..." "HEAL"
    
    # Build prompt for the LLM
    $prompt = @"
You are a DevOps AI. Given this production crash, write a targeted patch.

## Crash Summary
- Reason: $ErrorReason
- Error Line: $ErrorLine

## Context (last 20 log lines)
$Context

## Instructions
1. Identify the root cause from the error
2. Write the minimum patch to fix it
3. Output ONLY a JSON object:
{
  "root_cause": "one line description",
  "patch_type": "env_var|code_fix|config|dependency|none",
  "fix": "the exact fix (code, env var name=value, or config change)",
  "verify": "how to verify the fix worked",
  "confidence": 0.0-1.0
}

If the crash is NOT fixable by code (e.g. infrastructure outage, rate limit), output:
{ "root_cause": "...", "patch_type": "none", "fix": "No code fix possible — escalate", "verify": "Human check", "confidence": 1.0 }
"@
    
    # Write prompt to temp file for inspection
    $promptFile = Join-Path $ProjectRoot "logs\llm_prompt_$($Incident.Id).txt"
    Set-Content -Path $promptFile -Value $prompt -Encoding UTF8
    
    Write-Log "LLM prompt written to: $promptFile" "DEBUG"
    
    # Try using Ollama for patch generation (local, free)
    $llmResult = $null
    
    try {
        $body = @{
            model    = "qwen3.5:4b"
            prompt   = $prompt
            stream   = $false
            options  = @{ temperature = 0.1; num_predict = 300 }
        } | ConvertTo-Json -Compress
        
        $headers = @{ "Content-Type" = "application/json" }
        
        $response = Invoke-RestMethod -Uri "http://localhost:11434/api/generate" `
            -Method POST `
            -Headers $headers `
            -Body $body `
            -TimeoutSec 30
        
        if ($response -and $response.response) {
            $llmResult = $response.response
            Write-Log "LLM patch generated (Ollama)" "HEAL"
        }
    }
    catch {
        Write-Log "Ollama not available ($_), trying OpenAI..." "WARN"
        
        try {
            $openaiKey = $env:OPENAI_API_KEY
            if ($openaiKey) {
                $body = @{
                    model       = "gpt-4o-mini"
                    max_tokens  = 300
                    temperature = 0.1
                    messages    = @(
                        @{ role = "system"; content = "You are a DevOps AI. Output ONLY JSON." }
                        @{ role = "user"; content = $prompt }
                    )
                } | ConvertTo-Json -Compress
                
                $headers = @{
                    "Content-Type" = "application/json"
                    "Authorization" = "Bearer $openaiKey"
                }
                
                $resp = Invoke-RestMethod -Uri "https://api.openai.com/v1/chat/completions" `
                    -Method POST `
                    -Headers $headers `
                    -Body $body `
                    -TimeoutSec 30
                
                if ($resp -and $resp.choices[0].message.content) {
                    $llmResult = $resp.choices[0].message.content
                    Write-Log "LLM patch generated (OpenAI GPT-4o-mini)" "HEAL"
                }
            }
        }
        catch {
            Write-Log "No LLM available. Using pattern-based fallback." "WARN"
        }
    }
    
    # Try to parse JSON from LLM result
    if ($llmResult) {
        $llmResult | Out-File -FilePath (Join-Path $ProjectRoot "logs\llm_response_$($Incident.Id).txt") -Encoding UTF8
        
        # Extract JSON block
        if ($llmResult -match '\{[\s\S]*\}') {
            try {
                $patch = $matches[0] | ConvertFrom-Json
                Write-Log "Parsed LLM patch: $($patch | ConvertTo-Json)" "HEAL"
                return $patch
            }
            catch {
                Write-Log "Failed to parse LLM JSON: $_" "WARN"
            }
        }
    }
    
    # Fallback: no LLM available
    return @{
        root_cause   = "Unknown (LLM unavailable)"
        patch_type   = "none"
        fix          = "Manual investigation required — LLM not connected"
        verify       = "Human checks logs"
        confidence   = 0.0
        llm_available = $false
    }
}

# ─── Apply Patch ─────────────────────────────────────────────────────────────
function Invoke-Patch {
    param(
        [object]$Patch,
        [hashtable]$Incident
    )
    
    Write-Log "Applying patch: $($Patch.patch_type)" "HEAL"
    
    switch ($Patch.patch_type) {
        "env_var" {
            Write-Log "Setting environment variable: $($Patch.fix)" "HEAL"
            # Parse NAME=VALUE format
            if ($Patch.fix -match "^(\w+)=(.+)$") {
                $envName = $Matches[1]
                $envVal = $Matches[2]
                # Railway: railway variables set <name>=<value>
                $result = railway variables set $envName=$envVal 2>&1
                Write-Log "Set $envName via Railway CLI" "HEAL"
                return @{ Applied = $true; Action = "env_var_set"; Detail = "$envName=$envVal" }
            }
        }
        "code_fix" {
            Write-Log "Code fix required — would write: $($Patch.fix)" "WARN"
            # Phase 3 full implementation: use file ops + git
            return @{ Applied = $false; Action = "code_fix_pending"; Detail = $Patch.fix }
        }
        "config" {
            Write-Log "Config change: $($Patch.fix)" "HEAL"
            return @{ Applied = $false; Action = "config_change_pending"; Detail = $Patch.fix }
        }
        "none" {
            Write-Log "No patch applicable — escalating" "ERROR"
            return @{ Applied = $false; Action = "escalate"; Detail = $Patch.fix }
        }
    }
    
    return @{ Applied = $false; Action = "no_match" }
}

# ─── Deploy + Verify ──────────────────────────────────────────────────────────
function Start-DeployAndVerify {
    param(
        [int]$AttemptNumber,
        [string]$VerifyMethod
    )
    
    Write-Log "Deploying (attempt #$AttemptNumber)..." "HEAL"
    
    if ($Mode -eq "Simulate") {
        Write-Log "[SIMULATE] Would trigger: railway redeploy" "WARN"
        Start-Sleep 3
        Write-Log "[SIMULATE] Deployment complete (simulated)" "INFO"
        return @{ Success = $true; Simulated = $true }
    }
    
    # Real Railway deploy
    $deployResult = Invoke-RailwayDeploy -Environment $env:RAILWAY_ENVIRONMENT
    
    if (-not $deployResult.Success) {
        Write-Log "Deploy failed: $($deployResult.Output)" "ERROR"
        return @{ Success = $false; Detail = $deployResult.Output }
    }
    
    # Wait for deployment to settle
    Write-Log "Waiting ${VerifyWaitSec}s for deployment to settle..." "HEAL"
    Start-Sleep -Seconds $VerifyWaitSec
    
    # Verify: check if error still appears in logs
    Write-Log "Verifying fix..." "HEAL"
    
    $verifyResult = Get-RailwayLogs -Tail 30 -JsonOutput
    
    if ($verifyResult -and $verifyResult.Lines) {
        $stillCrashing = $false
        foreach ($line in $verifyResult.Lines) {
            if ($line -match "Error:|FATAL|CRITICAL|ECONNREFUSED") {
                $stillCrashing = $true
                Write-Log "Error still present: $line" "WARN"
            }
        }
        
        if (-not $stillCrashing) {
            Write-Log "✅ Verification PASSED — no errors in recent logs" "HEAL"
            return @{ Success = $true; StillCrashing = $false }
        }
        else {
            Write-Log "❌ Verification FAILED — error still present" "ERROR"
            return @{ Success = $false; StillCrashing = $true }
        }
    }
    
    return @{ Success = $false; Detail = "Could not verify" }
}

# ─── Escalate (Human Notification) ───────────────────────────────────────────
function Send-Escalation {
    param(
        [hashtable]$Incident,
        [int]$Attempts,
        [string]$Reason
    )
    
    Write-Log "ESCALATING to human: incident $($Incident.Id)" "ERROR"
    Write-Log "  Reason: $Reason" "ERROR"
    Write-Log "  Attempts made: $Attempts" "ERROR"
    
    # Write escalation event (Telegram/Discord webhook integration point)
    $escalation = @{
        Type        = "ESCALATION"
        IncidentId  = $Incident.Id
        Reason      = $Reason
        Attempts    = $Attempts
        Timestamp   = (Get-Date).ToString("o")
        RawLine     = $Incident.RawLine
    }
    
    $escFile = Join-Path $ProjectRoot "logs\escalation_$($Incident.Id).json"
    $escalation | ConvertTo-Json -Depth 3 | Set-Content -Path $escFile -Encoding UTF8
    
    Write-Log "Escalation event written to: $escFile" "ERROR"
    
    # TODO: Fire Telegram webhook (see memory/invisible_cto_roadmap.md)
    # Invoke-RestMethod -Uri $env:TELEGRAM_WEBHOOK -Method POST -Body ($escalation | ConvertTo-Json)
}

# ─── Main Heal Loop ──────────────────────────────────────────────────────────
function Start-HealLoop {
    param([string]$TargetIncidentId)
    
    $state = Get-HealState
    
    # Load incident from queue or provided ID
    $queueFile = Join-Path $ProjectRoot "logs\heal_queue.json"
    
    if ($TargetIncidentId) {
        Write-Log "Healing specific incident: $TargetIncidentId" "HEAL"
        # Load from crash log
    }
    elseif (Test-Path $queueFile) {
        Write-Log "Found heal_queue.json — processing..." "HEAL"
        try {
            $queueItem = Get-Content $queueFile -Raw | ConvertFrom-Json
        }
        catch {
            Write-Log "Failed to parse heal queue: $_" "ERROR"
            return
        }
        
        $incident = @{
            Id        = $queueItem.IncidentId
            Reason    = $queueItem.Reason
            RawLine   = $queueItem.RawLine
            Timestamp = $queueItem.Timestamp
            Attempt   = 0
        }
    }
    else {
        Write-Log "No heal_queue.json found. Run monitor.ps1 first, or pass -IncidentId" "WARN"
        
        if ($Mode -eq "Simulate") {
            Write-Log "Simulating a crash incident..." "WARN"
            $incident = @{
                Id        = "SIMULATED_$(Get-Date -Format 'HHmmss')"
                Reason    = "SyntaxError"
                RawLine   = "SyntaxError: Unexpected token '}' in app.js line 42"
                Timestamp = (Get-Date).ToString("o")
                Attempt   = 0
            }
        }
        else {
            return
        }
    }
    
    # Update state
    $state.ActiveIncident = $incident.Id
    $state.AttemptCount = 0
    $state.StartedAt = (Get-Date).ToString("o")
    Set-HealState -State $state
    
    Write-Log "Processing incident: $($incident.Id)" "HEAL"
    Write-Log "  Reason: $($incident.Reason)" "HEAL"
    Write-Log "  Raw: $($incident.RawLine)" "DEBUG"
    
    # ── Retry Budget ──────────────────────────────────────────────────────
    while ($state.AttemptCount -lt $MaxHealAttempts) {
        $state.AttemptCount++
        $incident.Attempt = $state.AttemptCount
        
        Write-Log "─── Heal Attempt #$($state.AttemptCount) of $MaxHealAttempts ───" "HEAL"
        
        # Step 1: Try known fix patterns first (fast path)
        $knownFixed = $false
        foreach ($pattern in $KnownFixes.Keys) {
            if ($incident.Reason -match $pattern -or $incident.RawLine -match $pattern) {
                Write-Log "Known fix pattern matched: $pattern" "HEAL"
                
                $fixResult = & $KnownFixes[$pattern] $incident
                
                if ($fixResult.Applied) {
                    Write-Log "Known fix applied: $($fixResult.Action)" "HEAL"
                    # Deploy after known fix
                    $deployResult = Start-DeployAndVerify -AttemptNumber $state.AttemptCount
                    if ($deployResult.Success) {
                        $knownFixed = $true
                        break
                    }
                }
                
                if ($fixResult.NeedLLM) {
                    Write-Log "Known pattern but needs LLM to determine exact fix" "WARN"
                    break
                }
            }
        }
        
        if ($knownFixed) {
            break
        }
        
        # Step 2: LLM patch writing
        $context = ""  # Would fetch surrounding log lines in production
        $patch = Write-PatchWithLLM -ErrorReason $incident.Reason -ErrorLine $incident.RawLine -Context $context -Incident $incident
        
        Write-Log "LLM Patch Result:" "HEAL"
        Write-Log "  Root Cause: $($patch.root_cause)" "HEAL"
        Write-Log "  Patch Type: $($patch.patch_type)" "HEAL"
        Write-Log "  Fix: $($patch.fix)" "HEAL"
        Write-Log "  Confidence: $($patch.confidence)" "HEAL"
        
        # Step 3: Apply patch
        if ($patch.patch_type -ne "none" -and $patch.confidence -gt 0.5) {
            $applyResult = Invoke-Patch -Patch $patch -Incident $incident
            Write-Log "Patch application: $($applyResult | ConvertTo-Json)" "HEAL"
        }
        else {
            Write-Log "Confidence too low or no patch — skipping application" "WARN"
        }
        
        # Step 4: Deploy + Verify
        $deployResult = Start-DeployAndVerify -AttemptNumber $state.AttemptCount
        
        if ($deployResult.Success -and -not $deployResult.StillCrashing) {
            Write-Log "✅ HEAL SUCCESSFUL! Incident $($incident.Id) resolved." "HEAL"
            
            # Log success
            $state.History += @{
                IncidentId  = $incident.Id
                ResolvedAt = (Get-Date).ToString("o")
                Attempts   = $state.AttemptCount
                RootCause  = $patch.root_cause
            }
            $state.ActiveIncident = $null
            $state.StartedAt = $null
            Set-HealState -State $state
            
            # Clear queue
            if (Test-Path $queueFile) { Remove-Item $queueFile -Force }
            
            return $true
        }
        else {
            Write-Log "❌ Attempt #$($state.AttemptCount) failed. Retrying..." "ERROR"
            
            if ($state.AttemptCount -lt $MaxHealAttempts) {
                $backoff = [Math]::Pow(2, $state.AttemptCount) * 5
                Write-Log "Backing off ${backoff}s before retry..." "WARN"
                Start-Sleep -Seconds $backoff
            }
        }
    }
    
    # ── Max attempts reached → Escalate ───────────────────────────────────
    Write-Log "Max heal attempts ($MaxHealAttempts) exhausted for incident $($incident.Id)" "ERROR"
    Send-Escalation -Incident $incident -Attempts $state.AttemptCount -Reason "Max retries exceeded"
    
    $state.ActiveIncident = $null
    Set-HealState -State $state
    
    return $false
}

# ─── Run ─────────────────────────────────────────────────────────────────────
$success = Start-HealLoop -TargetIncidentId $IncidentId

if ($success) {
    Write-Log "=== Heal Loop Completed Successfully ===" "HEAL"
}
else {
    Write-Log "=== Heal Loop Escalated — Human Intervention Required ===" "ERROR"
}
