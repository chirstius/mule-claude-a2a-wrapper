#requires -Version 5.1
<#
.SYNOPSIS
  Exercises the deployed Mule wrapper locally: fetches the agent card, then sends an A2A
  JSON-RPC message/send. Run AFTER the app is deployed in Studio (with -M-Dclaude.apiKey set
  for the message/send to actually reach Claude).
#>
[CmdletBinding()]
param(
  [string]$BaseUrl   = "http://localhost:8081",
  [string]$AgentPath = "/a2a",
  [string]$Prompt    = "In one sentence, what is the A2A protocol?"
)
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Show-HttpError($err) {
  $resp = $err.Exception.Response
  if ($resp -and $resp.GetResponseStream) {
    $sr = New-Object IO.StreamReader($resp.GetResponseStream())
    Write-Warning ("HTTP " + [int]$resp.StatusCode + ": " + $sr.ReadToEnd())
  } else {
    Write-Warning $err.Exception.Message
  }
}

Write-Host "==> GET agent card (no secret needed)..." -ForegroundColor Cyan
foreach ($cardUrl in @("$BaseUrl/.well-known/agent-card.json", "$BaseUrl$AgentPath/.well-known/agent-card.json")) {
  try {
    $card = Invoke-RestMethod -Method Get -Uri $cardUrl
    Write-Host ("    [200] " + $cardUrl) -ForegroundColor Green
    Write-Host ("    name: " + $card.name + "  protocol: " + $card.protocolVersion + "  streaming: " + $card.capabilities.streaming)
    break
  } catch {
    Write-Host ("    [miss] " + $cardUrl) -ForegroundColor DarkGray
  }
}

Write-Host "`n==> POST message/send (JSON-RPC) to $BaseUrl$AgentPath ..." -ForegroundColor Cyan
$body = @{
  jsonrpc = "2.0"
  id      = "test-1"
  method  = "message/send"
  params  = @{
    message = @{
      role      = "user"
      kind      = "message"
      messageId = [guid]::NewGuid().ToString()
      parts     = @( @{ kind = "text"; text = $Prompt } )
    }
  }
} | ConvertTo-Json -Depth 10

try {
  $resp = Invoke-RestMethod -Method Post -Uri "$BaseUrl$AgentPath" -ContentType "application/json" -Body $body
  Write-Host "    raw response:" -ForegroundColor Green
  $resp | ConvertTo-Json -Depth 12
} catch {
  Show-HttpError $_
}
