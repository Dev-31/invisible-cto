# vercel_wrapper.ps1 — Vercel REST API wrapper
# Secondary platform for Invisible CTO (less ideal for self-healing — limited log access)

param(
    [string]$Token = $env:VERCEL_API_TOKEN,
    [string]$TeamId = $env:VERCEL_TEAM_ID
)

$ErrorActionPreference = "Continue"

$BaseUrl = "https://api.vercel.com"
$Headers = @{
    "Authorization" = "Bearer $Token"
    "Content-Type"  = "application/json"
}

# ─── Helpers ──────────────────────────────────────────────────────────────────

function Invoke-VercelAPI {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [string]$Method = "GET",
        [hashtable]$Body,
        [int]$TimeoutSec = 30
    )
    
    $url = if ($Path -match '^https?://') { $Path } else { "$BaseUrl$Path" }
    
    $params = @{
        Uri         = $url
        Method      = $Method
        Headers     = $Headers
        TimeoutSec  = $TimeoutSec
    }
    
    if ($Body) {
        $params.Body = ($Body | ConvertTo-Json -Compress)
    }
    
    try {
        $resp = Invoke-RestMethod @params
        return @{ Success = $true; Data = $resp }
    }
    catch {
        $status = $_.Exception.Response.StatusCode.value__
        $detail = try { $_.ErrorDetails.Message } catch { $_.Exception.Message }
        return @{
            Success = $false
            Status  = $status
            Error   = $detail ?? $_.Exception.Message
        }
    }
}

# ─── Deployment Operations ─────────────────────────────────────────────────────

function Get-VercelDeployments {
    param([int]$Limit = 20)
    
    $path = "/v6/deployments?limit=$Limit"
    if ($TeamId) { $path += "&teamId=$TeamId" }
    
    $result = Invoke-VercelAPI -Path $path
    if ($result.Success) {
        return @{
            Success     = $true
            Deployments = $result.Data.deployments
        }
    }
    return $result
}

function Get-VercelDeploymentLogs {
    <#
    .SYNOPSIS
        Vercel log retrieval — NOTE: Only BUILD logs, not production runtime logs!
        This is a key limitation of Vercel for self-healing use cases.
    .PARAMETER DeploymentId
        Deployment ID (from Get-VercelDeployments)
    #>
    param(
        [Parameter(Mandatory)]
        [string]$DeploymentId
    )
    
    # Vercel doesn't provide production runtime logs via API
    # Only build/deployment event logs
    $path = "/v2/deployments/$DeploymentId/events"
    $result = Invoke-VercelAPI -Path $path
    
    if ($result.Success) {
        return @{
            Success = $true
            Events  = $result.Data.events
            Note    = "Vercel only provides BUILD logs, not production runtime logs"
        }
    }
    return $result
}

function Invoke-VercelRedeploy {
    param(
        [Parameter(Mandatory)]
        [string]$DeploymentId
    )
    
    $path = "/v1/deployments/$DeploymentId/redeploy"
    $result = Invoke-VercelAPI -Path $path -Method "POST"
    return $result
}

function Get-VercelProject {
    param([string]$ProjectName)
    
    $path = "/v2/projects/$ProjectName"
    if ($TeamId) { $path += "?teamId=$TeamId" }
    
    return Invoke-VercelAPI -Path $path
}

# ─── Health Check ──────────────────────────────────────────────────────────────

function Test-VercelHealth {
    $result = Invoke-VercelAPI -Path "/v2/user"
    
    if ($result.Success) {
        return @{
            Healthy    = $true
            User       = $result.Data.user.name
            Username   = $result.Data.user.username
        }
    }
    return @{
        Healthy = $false
        Error   = $result.Error
        Hint    = "Set `$env:VERCEL_API_TOKEN"
    }
}

# ─── Environment Variables ────────────────────────────────────────────────────

function Get-VercelEnvVars {
    param([string]$ProjectId)
    
    $path = "/v10/projects/$ProjectId/env?decrypt=true"
    if ($TeamId) { $path += "&teamId=$TeamId" }
    
    return Invoke-VercelAPI -Path $path
}

function Set-VercelEnvVar {
    param(
        [Parameter(Mandatory)]
        [string]$ProjectId,
        [Parameter(Mandatory)]
        [string]$Key,
        [Parameter(Mandatory)]
        [string]$Value,
        [string]$Type = "plain",   # plain | secret | encrypted
        [string]$Environment = "production"
    )
    
    $body = @{
        key    = $Key
        value  = $Value
        type   = $Type
        environment = $Environment
    }
    
    $path = "/v10/projects/$ProjectId/env"
    if ($TeamId) { $path += "?teamId=$TeamId" }
    
    return Invoke-VercelAPI -Path $path -Method "POST" -Body $body
}

# ─── Export ───────────────────────────────────────────────────────────────────
Export-ModuleMember -Function @(
    "Get-VercelDeployments",
    "Get-VercelDeploymentLogs",
    "Invoke-VercelRedeploy",
    "Get-VercelProject",
    "Test-VercelHealth",
    "Get-VercelEnvVars",
    "Set-VercelEnvVar"
)
