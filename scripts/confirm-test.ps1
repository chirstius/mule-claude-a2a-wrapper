#requires -Version 5.1
<#
.SYNOPSIS
  End-to-end test of the A2A tool-confirmation (input-required) HITL round-trip against the
  deployed Mule wrapper. Requires the wrapper pointed at the CONFIRM agent (agent-confirm) with
  confirmation.default = defer (so a tool call surfaces as input-required).
.DESCRIPTION
  1) POST message/send with a prompt that uses a tool -> expect a Task in state 'input-required'
     carrying a tool-confirmation-request DataPart (calls[] with toolUseId/name/input).
  2) POST message/send again on the SAME contextId with a tool-confirmation-response DataPart
     (allow or deny each toolUseId) -> expect a 'completed' Task with the answer (allow) or the
     agent working around the denial (deny).
#>
[CmdletBinding()]
param(
  [string]$BaseUrl   = "http://localhost:8081",
  [string]$AgentPath = "/a2a",
  [string]$Prompt    = "Create a file named approval-demo.txt containing a short haiku about gatekeeping, then tell me what you wrote.",
  [ValidateSet("allow","deny")][string]$Decision = "allow",
  [string]$DenyMessage = "Policy: not allowed to write that file. Just tell me the haiku instead.",
  [int]$DelaySeconds = 0
)
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Show-HttpError($err) {
  $resp = $err.Exception.Response
  if ($resp -and $resp.GetResponseStream) {
    $sr = New-Object IO.StreamReader($resp.GetResponseStream())
    Write-Warning ("HTTP " + [int]$resp.StatusCode + ": " + $sr.ReadToEnd())
  } else { Write-Warning $err.Exception.Message }
}

function Send-Message($ctx, $parts) {
  $body = @{
    jsonrpc = "2.0"
    id      = [guid]::NewGuid().ToString()
    method  = "message/send"
    params  = @{
      message = @{
        role      = "user"
        kind      = "message"
        messageId = [guid]::NewGuid().ToString()
        contextId = $ctx
        parts     = $parts
      }
    }
  } | ConvertTo-Json -Depth 20
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
  return Invoke-RestMethod -Method Post -Uri "$BaseUrl$AgentPath" -ContentType "application/json" -Body $bytes
}

$ctx = "ctx-confirm-" + [guid]::NewGuid().ToString()
Write-Host "==> contextId: $ctx" -ForegroundColor DarkGray

# ---- Turn 1: prompt that triggers a gated tool ----
Write-Host "`n==> [1] message/send (prompt that uses a tool)..." -ForegroundColor Cyan
try {
  $r1 = Send-Message $ctx @( @{ kind = "text"; text = $Prompt } )
} catch { Show-HttpError $_; return }

$task1 = $r1.result
Write-Host ("    state: " + $task1.status.state) -ForegroundColor Green
if ($task1.status.state -ne "input-required") {
  Write-Warning "Expected 'input-required'. Is the wrapper pointed at the confirm agent with confirmation.default=defer?"
  Write-Host "Full response:" -ForegroundColor DarkGray
  $r1 | ConvertTo-Json -Depth 20
  return
}

# Extract the tool-confirmation-request DataPart.
$reqPart = $task1.status.message.parts | Where-Object { $_.kind -eq "data" -and $_.data.type -eq "tool-confirmation-request" } | Select-Object -First 1
if (-not $reqPart) { Write-Warning "No tool-confirmation-request DataPart found."; $r1 | ConvertTo-Json -Depth 20; return }
$calls = @($reqPart.data.calls)
Write-Host "    pending tool calls:" -ForegroundColor Cyan
foreach ($c in $calls) {
  $fp = $c.input.file_path
  Write-Host ("      - " + $c.toolUseId + "  [" + $c.name + "]" + $(if ($fp) { " -> $fp" } else { "" }))
}

if ($DelaySeconds -gt 0) {
  Write-Host "`n==> Simulating caller think-time: waiting $DelaySeconds s before answering" -ForegroundColor Yellow
  Start-Sleep -Seconds $DelaySeconds
}

# ---- Turn 2: answer with a tool-confirmation-response on the SAME contextId ----
Write-Host "`n==> [2] message/send (tool-confirmation-response = $Decision) on same contextId..." -ForegroundColor Cyan
$decisions = @()
foreach ($c in $calls) {
  $d = @{ toolUseId = $c.toolUseId; result = $Decision }
  if ($Decision -eq "deny") { $d.denyMessage = $DenyMessage }
  $decisions += $d
}
$respPart = @{ kind = "data"; data = @{ type = "tool-confirmation-response"; decisions = $decisions } }
# A small text part too (callers usually attach one); the wrapper keys off the DataPart.
$parts2 = @( @{ kind = "text"; text = "Here is my decision." }, $respPart )

try {
  $r2 = Send-Message $ctx $parts2
} catch { Show-HttpError $_; return }

$task2 = $r2.result
Write-Host ("    state: " + $task2.status.state) -ForegroundColor Green
Write-Host "`n==> Final answer / artifacts:" -ForegroundColor Cyan
if ($task2.artifacts) {
  foreach ($a in $task2.artifacts) {
    Write-Host ("  [" + $a.name + "]") -ForegroundColor Magenta
    foreach ($p in $a.parts) { if ($p.kind -eq "text") { Write-Host ("    " + $p.text) } }
  }
} else {
  Write-Host "  (no artifacts) full response:" -ForegroundColor DarkGray
  $r2 | ConvertTo-Json -Depth 20
}
Write-Host "`nConfirmation round-trip complete." -ForegroundColor Green
