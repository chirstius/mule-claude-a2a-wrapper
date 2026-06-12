#requires -Version 5.1
<#
.SYNOPSIS
  End-to-end check of the Claude managed agent WITHOUT Mule.
.DESCRIPTION
  Creates a session against the agent+environment from ids.json, sends a user.message, polls until the
  session goes idle, then prints the agent's text output, any files it produced, and token usage.
  This is the "known-good target" you test the A2A wrapper against.
#>
[CmdletBinding()]
param(
  [string]$Prompt = "Create a file named hello.txt containing a short haiku about enterprise integration, then tell me what you wrote.",
  [string]$EnvFile = (Join-Path $PSScriptRoot ".env"),
  [int]$TimeoutSeconds = 240
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
  throw "ANTHROPIC_API_KEY not set. Set the env var or add it to $EnvFile."
}

$idsPath = Join-Path $PSScriptRoot "ids.json"
if (-not (Test-Path $idsPath)) { throw "ids.json not found. Run .\setup.ps1 first." }
$ids = Get-Content $idsPath -Raw | ConvertFrom-Json

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
      $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
      throw "API $Method $Path failed ($([int]$resp.StatusCode)): $($reader.ReadToEnd())"
    }
    throw
  }
}

Write-Host "==> Creating session (agent $($ids.agent_id))..." -ForegroundColor Cyan
$session = Invoke-Anthropic -Method Post -Path "/sessions" -Body @{
  agent          = $ids.agent_id
  environment_id = $ids.environment_id
}
$sid = $session.id
Write-Host "    session id: $sid" -ForegroundColor Green

Write-Host "==> Sending prompt..." -ForegroundColor Cyan
Write-Host "    `"$Prompt`"" -ForegroundColor DarkGray
Invoke-Anthropic -Method Post -Path "/sessions/$sid/events" -Body @{
  events = @( @{ type = "user.message"; content = @( @{ type = "text"; text = $Prompt } ) } )
} | Out-Null

Write-Host "==> Working (polling session status)..." -ForegroundColor Cyan
$deadline    = (Get-Date).AddSeconds($TimeoutSeconds)
$seenRunning = $false
$final       = $null
do {
  Start-Sleep -Seconds 3
  $s = Invoke-Anthropic -Method Get -Path "/sessions/$sid"
  Write-Host "    status: $($s.status)" -ForegroundColor DarkGray
  if ($s.status -eq "running") { $seenRunning = $true }
  if ($s.status -in @("failed","error")) { throw "Session ended with status '$($s.status)'." }
  if ($s.status -eq "idle" -and $seenRunning) { $final = $s; break }
  if ((Get-Date) -gt $deadline) { throw "Timed out after $TimeoutSeconds s (last status: $($s.status))." }
} while ($true)

Write-Host "`n==> Agent output:" -ForegroundColor Cyan
$events = Invoke-Anthropic -Method Get -Path "/sessions/$sid/events"
foreach ($e in $events.data) {
  if ($e.type -eq "agent.message" -and $e.content) {
    foreach ($block in $e.content) {
      if ($block.type -eq "text") { Write-Host $block.text }
    }
  }
}

# Surface files the agent wrote (these become A2A artifacts in the wrapper).
$writes = $events.data | Where-Object { $_.type -eq "agent.tool_use" -and ($_.name -in @("Write","Edit","MultiEdit")) }
if ($writes) {
  Write-Host "`n==> Files the agent touched (future A2A artifacts):" -ForegroundColor Cyan
  foreach ($w in $writes) {
    $path = $w.input.file_path; if (-not $path) { $path = $w.input.path }
    Write-Host "    [$($w.name)] $path"
  }
}

if ($final.usage) {
  Write-Host "`n==> Token usage:" -ForegroundColor Cyan
  Write-Host "    input  : $($final.usage.input_tokens)"
  Write-Host "    output : $($final.usage.output_tokens)"
  Write-Host "    cache_read    : $($final.usage.cache_read_input_tokens)"
  Write-Host "    cache_creation: $($final.usage.cache_creation_input_tokens)"
}
Write-Host "`nSmoke test complete. Session $sid is idle and resumable." -ForegroundColor Green
