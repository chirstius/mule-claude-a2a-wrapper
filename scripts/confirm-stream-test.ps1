#requires -Version 5.1
<#
.SYNOPSIS
  End-to-end STREAMING tool-confirmation (input-required) round-trip against the deployed wrapper.
  Requires the wrapper pointed at the CONFIRM agent with confirmation.default = defer.
.DESCRIPTION
  Turn 1: message/stream a prompt that uses a tool. The SSE stream relays 'working' updates and then
          ENDS on a final 'input-required' status carrying a tool-confirmation-request DataPart. (The
          stream closing here is by design - we do NOT hold a connection open across the think-time.)
  Turn 2: message/stream again on the SAME contextId with a tool-confirmation-response DataPart; the
          stream resumes and ends on 'completed' with the answer artifact.
  Uses curl.exe -N. Each turn's stream is finite (it closes on the final status), so we collect the
  lines, print them, and parse the 'data:' frames to drive the next turn.
#>
[CmdletBinding()]
param(
  [string]$Url      = "http://localhost:8081/a2a",
  [string]$Prompt   = "Create a file named stream-approval.txt with a short haiku about gates, then tell me what you wrote.",
  [ValidateSet("allow","deny")][string]$Decision = "allow",
  [string]$DenyMessage = "Policy: do not write that file; just tell me the haiku.",
  [int]$DelaySeconds = 0
)
$ErrorActionPreference = "Stop"

function Invoke-Stream($ctx, $parts, $label) {
  $body = @{
    jsonrpc = "2.0"; id = [guid]::NewGuid().ToString(); method = "message/stream"
    params = @{ message = @{ role = "user"; kind = "message"; messageId = [guid]::NewGuid().ToString(); contextId = $ctx; parts = $parts } }
  } | ConvertTo-Json -Depth 20 -Compress
  $tmp = [IO.Path]::GetTempFileName()
  [IO.File]::WriteAllText($tmp, $body, (New-Object Text.UTF8Encoding $false))
  Write-Host "`n---- [$label] SSE stream ----" -ForegroundColor Cyan
  try {
    $lines = & curl.exe -N -s -S -X POST $Url -H "content-type: application/json" -H "accept: text/event-stream" --data "@$tmp"
  } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
  foreach ($l in $lines) { Write-Host "    $l" -ForegroundColor DarkGray }
  return $lines
}

# Parse all 'data:' frames and UNWRAP the JSON-RPC envelope to its .result (the A2A object).
function Get-Frames($lines) {
  $objs = @()
  foreach ($l in $lines) {
    if ($l -like "data:*") {
      $j = $l.Substring(5).Trim()
      if ($j) { try { $o = $j | ConvertFrom-Json; if ($o.result) { $objs += $o.result } } catch {} }
    }
  }
  return $objs
}

$ctx = "ctx-stream-confirm-" + [guid]::NewGuid().ToString()
Write-Host "==> contextId: $ctx" -ForegroundColor DarkGray

# ---- Turn 1 ----
$lines1 = Invoke-Stream $ctx @( @{ kind = "text"; text = $Prompt } ) "turn 1: prompt"
$frames1 = Get-Frames $lines1

# Find the tool-confirmation-request DataPart anywhere in the streamed frames.
$reqPart = $null
foreach ($f in $frames1) {
  $parts = $f.status.message.parts
  if ($parts) {
    $p = $parts | Where-Object { $_.kind -eq "data" -and $_.data.type -eq "tool-confirmation-request" } | Select-Object -First 1
    if ($p) { $reqPart = $p; break }
  }
}
if (-not $reqPart) {
  Write-Warning "No input-required / tool-confirmation-request frame seen. Is the wrapper on the confirm agent with confirmation.default=defer?"
  return
}
$calls = @($reqPart.data.calls)
Write-Host "`n==> pending tool calls:" -ForegroundColor Cyan
foreach ($c in $calls) { Write-Host ("      - " + $c.toolUseId + "  [" + $c.name + "]" + $(if ($c.input.file_path) { " -> " + $c.input.file_path } else { "" })) }

if ($DelaySeconds -gt 0) {
  Write-Host "`n==> Simulating caller think-time: waiting $DelaySeconds s before answering" -ForegroundColor Yellow
  Write-Host "    (turn-1 stream is already CLOSED; the Claude session waits at requires_action)" -ForegroundColor DarkGray
  Start-Sleep -Seconds $DelaySeconds
}

# ---- Turn 2: answer on the SAME contextId ----
$decisions = @()
foreach ($c in $calls) {
  $d = @{ toolUseId = $c.toolUseId; result = $Decision }
  if ($Decision -eq "deny") { $d.denyMessage = $DenyMessage }
  $decisions += $d
}
$parts2 = @(
  @{ kind = "text"; text = "Here is my decision." },
  @{ kind = "data"; data = @{ type = "tool-confirmation-response"; decisions = $decisions } }
)
$lines2 = Invoke-Stream $ctx $parts2 "turn 2: $Decision -> resume"
$frames2 = Get-Frames $lines2

$completed = $frames2 | Where-Object { $_.status.state -eq "completed" } | Select-Object -First 1
$artifact  = $frames2 | Where-Object { $_.artifact } | Select-Object -First 1
Write-Host "`n==> Result:" -ForegroundColor Cyan
if ($artifact) { foreach ($p in $artifact.artifact.parts) { if ($p.kind -eq "text") { Write-Host ("    " + $p.text) } } }
Write-Host ("    terminal state seen: " + ($completed -ne $null)) -ForegroundColor Green
Write-Host "`nStreaming confirmation round-trip complete." -ForegroundColor Green
