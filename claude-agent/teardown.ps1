#requires -Version 5.1
<#
.SYNOPSIS
  Archives the agent and archives+deletes the environment created by setup.ps1.
.NOTES
  Archiving makes resources read-only (existing sessions keep running). Environment delete only
  succeeds if no sessions still reference it. Removes ids.json / .env.local on success.
#>
[CmdletBinding()]
param([string]$EnvFile = (Join-Path $PSScriptRoot ".env"))

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Get-ApiKey {
  if ($env:ANTHROPIC_API_KEY) { return $env:ANTHROPIC_API_KEY }
  if (Test-Path $EnvFile) {
    foreach ($line in Get-Content $EnvFile) {
      if ($line -match '^\s*ANTHROPIC_API_KEY\s*=\s*(.+?)\s*$') { return $Matches[1].Trim('"') }
    }
  }
  throw "ANTHROPIC_API_KEY not set."
}

$idsPath = Join-Path $PSScriptRoot "ids.json"
if (-not (Test-Path $idsPath)) { throw "ids.json not found — nothing to tear down." }
$ids = Get-Content $idsPath -Raw | ConvertFrom-Json

$headers = @{
  "x-api-key"         = (Get-ApiKey)
  "anthropic-version" = "2023-06-01"
  "anthropic-beta"    = "managed-agents-2026-04-01"
  "content-type"      = "application/json"
}
$base = "https://api.anthropic.com/v1"

function Try-Call { param([string]$Method,[string]$Path)
  try { Invoke-RestMethod -Method $Method -Uri "$base$Path" -Headers $headers | Out-Null; Write-Host "    ok: $Method $Path" -ForegroundColor Green }
  catch { Write-Warning "    $Method $Path -> $($_.Exception.Message)" }
}

Write-Host "==> Archiving agent $($ids.agent_id)..." -ForegroundColor Cyan
Try-Call -Method Post -Path "/agents/$($ids.agent_id)/archive"

Write-Host "==> Archiving environment $($ids.environment_id)..." -ForegroundColor Cyan
Try-Call -Method Post -Path "/environments/$($ids.environment_id)/archive"

Write-Host "==> Deleting environment $($ids.environment_id)..." -ForegroundColor Cyan
Try-Call -Method Delete -Path "/environments/$($ids.environment_id)"

Remove-Item $idsPath -ErrorAction SilentlyContinue
Remove-Item (Join-Path $PSScriptRoot ".env.local") -ErrorAction SilentlyContinue
Write-Host "`nTeardown done (ids.json / .env.local removed)." -ForegroundColor Green
