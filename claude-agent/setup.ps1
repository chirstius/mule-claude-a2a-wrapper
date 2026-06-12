#requires -Version 5.1
<#
.SYNOPSIS
  Creates the Claude managed agent + cloud environment that the A2A wrapper sits in front of.
.DESCRIPTION
  Reads environment.json and agent.json, POSTs them to the Managed Agents API, and saves the
  resulting IDs to ids.json (gitignored) and .env.local. Run smoke-test.ps1 afterwards to verify.
#>
[CmdletBinding()]
param(
  [string]$Model          = $(if ($env:ANTHROPIC_MODEL) { $env:ANTHROPIC_MODEL } else { "claude-sonnet-4-5" }),
  [string]$EnvFile        = (Join-Path $PSScriptRoot ".env"),
  [string]$EnvironmentDef = (Join-Path $PSScriptRoot "environment.json"),
  [string]$AgentDef       = (Join-Path $PSScriptRoot "agent.json")
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Get-ApiKey {
  if ($env:ANTHROPIC_API_KEY) { return $env:ANTHROPIC_API_KEY }
  if (Test-Path $EnvFile) {
    foreach ($line in Get-Content $EnvFile) {
      if ($line -match '^\s*ANTHROPIC_API_KEY\s*=\s*(.+?)\s*$') { return $Matches[1].Trim('"') }
    }
  }
  throw "ANTHROPIC_API_KEY not set. Set the env var or add it to $EnvFile (copy .env.example)."
}

$script:Headers = @{
  "x-api-key"         = (Get-ApiKey)
  "anthropic-version" = "2023-06-01"
  "anthropic-beta"    = "managed-agents-2026-04-01"
  "content-type"      = "application/json"
}
$script:Base = "https://api.anthropic.com/v1"

function Invoke-Anthropic {
  param([string]$Method, [string]$Path, $Body)
  $uri = "$script:Base$Path"
  try {
    if ($null -ne $Body) {
      $json = if ($Body -is [string]) { $Body } else { ConvertTo-Json -InputObject $Body -Depth 25 }
      return Invoke-RestMethod -Method $Method -Uri $uri -Headers $script:Headers -Body $json
    }
    return Invoke-RestMethod -Method $Method -Uri $uri -Headers $script:Headers
  } catch {
    $resp = $_.Exception.Response
    if ($resp -and $resp.GetResponseStream) {
      $reader  = New-Object System.IO.StreamReader($resp.GetResponseStream())
      $errBody = $reader.ReadToEnd()
      throw "API $Method $Path failed ($([int]$resp.StatusCode) $($resp.StatusCode)): $errBody"
    }
    throw
  }
}

Write-Host "==> Creating cloud environment..." -ForegroundColor Cyan
$envDef = Get-Content $EnvironmentDef -Raw | ConvertFrom-Json
# Check-first so re-runs reuse the environment instead of creating duplicates.
$existingEnv = (Invoke-Anthropic -Method Get -Path "/environments").data |
               Where-Object { $_.name -eq $envDef.name -and -not $_.archived_at } | Select-Object -First 1
if ($existingEnv) {
  $environment = $existingEnv
  Write-Host "    reusing existing environment '$($envDef.name)'" -ForegroundColor Yellow
} else {
  $environment = Invoke-Anthropic -Method Post -Path "/environments" -Body $envDef
}
Write-Host "    environment id : $($environment.id)" -ForegroundColor Green

Write-Host "==> Creating managed agent (model: $Model)..." -ForegroundColor Cyan
$agentDef = Get-Content $AgentDef -Raw | ConvertFrom-Json
$agentDef | Add-Member -NotePropertyName model -NotePropertyValue $Model -Force
$agent = Invoke-Anthropic -Method Post -Path "/agents" -Body $agentDef
Write-Host "    agent id       : $($agent.id)" -ForegroundColor Green
Write-Host "    agent version  : $($agent.version)" -ForegroundColor Green

# Persist IDs for the smoke test and the Mule wrapper config.
$ids = [ordered]@{
  agent_id       = $agent.id
  agent_version  = $agent.version
  environment_id = $environment.id
  model          = $Model
}
$ids | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $PSScriptRoot "ids.json")

@(
  "ANTHROPIC_AGENT_ID=$($agent.id)"
  "ANTHROPIC_AGENT_VERSION=$($agent.version)"
  "ANTHROPIC_ENVIRONMENT_ID=$($environment.id)"
) | Set-Content -Encoding UTF8 (Join-Path $PSScriptRoot ".env.local")

Write-Host "`nSaved ids.json and .env.local." -ForegroundColor Green
Write-Host "Next: .\smoke-test.ps1   (verifies the agent responds before you build the Mule wrapper)"
