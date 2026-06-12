#requires -Version 5.1
<#
.SYNOPSIS
  Multi-turn test: proves the wrapper reuses the same Claude session across two A2A
  message/send calls that share a contextId (exercises the contextId -> sessionId store).
  Turn 1 establishes a fact; Turn 2 (same contextId) checks the agent remembers it.
#>
[CmdletBinding()]
param(
  [string]$BaseUrl   = "http://localhost:8081",
  [string]$AgentPath = "/a2a"
)
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Send-A2A($prompt, $contextId) {
  $msg = @{ role = "user"; kind = "message"; messageId = [guid]::NewGuid().ToString(); parts = @(@{ kind = "text"; text = $prompt }) }
  if ($contextId) { $msg.contextId = $contextId }
  $body = @{ jsonrpc = "2.0"; id = [guid]::NewGuid().ToString(); method = "message/send"; params = @{ message = $msg } } | ConvertTo-Json -Depth 12
  return Invoke-RestMethod -Method Post -Uri "$BaseUrl$AgentPath" -ContentType "application/json" -Body $body
}

Write-Host "==> Turn 1 (no contextId): establish a fact" -ForegroundColor Cyan
$r1   = Send-A2A "My name is Chuck and my favorite color is teal. Acknowledge in one short sentence." $null
$ctx1 = $r1.result.contextId
Write-Host ("    contextId: " + $ctx1) -ForegroundColor DarkGray
Write-Host ("    answer   : " + $r1.result.artifacts[0].parts[0].text)

Write-Host "`n==> Turn 2 (SAME contextId): test memory / session reuse" -ForegroundColor Cyan
$r2   = Send-A2A "Without being told again, what is my name and favorite color?" $ctx1
$ctx2 = $r2.result.contextId
Write-Host ("    contextId: " + $ctx2) -ForegroundColor DarkGray
Write-Host ("    answer   : " + $r2.result.artifacts[0].parts[0].text)

Write-Host "`n==> Verdict:" -ForegroundColor Cyan
if ($ctx2 -eq $ctx1) { Write-Host "    [ok] contextId preserved across turns" -ForegroundColor Green }
else { Write-Host "    [!] contextId changed ($ctx1 -> $ctx2) - mapping not via message.contextId" -ForegroundColor Yellow }
$mem = "" + $r2.result.artifacts[0].parts[0].text
if ($mem -match "Chuck" -and $mem -match "teal") { Write-Host "    [ok] agent recalled name + color -> Claude session was REUSED" -ForegroundColor Green }
else { Write-Host "    [!] memory not confirmed - inspect the Turn 2 answer above" -ForegroundColor Yellow }
