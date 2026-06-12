#requires -Version 5.1
<#
.SYNOPSIS
  Drives the streaming path: POSTs an A2A message/stream and prints the raw SSE events as
  they arrive (status-update / artifact-update). Uses a prompt that triggers a tool call so
  you can watch the per-tool relay ("Using tool(s): write -> /...") show up live.
  Uses curl.exe -N (no buffering) because Invoke-RestMethod buffers the whole response.
#>
[CmdletBinding()]
param(
  [string]$Url    = "http://localhost:8081/a2a",
  [string]$Prompt = "Create a file named haiku.txt containing a haiku about streaming data, then briefly tell me what you wrote."
)
$ErrorActionPreference = "Stop"

$body = @{
  jsonrpc = "2.0"
  id      = "stream-1"
  method  = "message/stream"
  params  = @{
    message = @{
      role      = "user"
      kind      = "message"
      messageId = [guid]::NewGuid().ToString()
      parts     = @( @{ kind = "text"; text = $Prompt } )
    }
  }
} | ConvertTo-Json -Depth 12 -Compress

# BOM-less UTF-8 temp file so curl sends clean JSON (avoids quoting hell + BOM corruption).
$tmp = [IO.Path]::GetTempFileName()
[IO.File]::WriteAllText($tmp, $body, (New-Object Text.UTF8Encoding $false))

Write-Host "POST message/stream -> $Url" -ForegroundColor Cyan
Write-Host "prompt: $Prompt" -ForegroundColor DarkGray
Write-Host "---- SSE stream (events arrive as the agent works) ----" -ForegroundColor Cyan
try {
  curl.exe -N -s -S -X POST $Url `
    -H "content-type: application/json" `
    -H "accept: text/event-stream" `
    --data "@$tmp"
} finally {
  Remove-Item $tmp -ErrorAction SilentlyContinue
}
Write-Host "`n---- stream closed ----" -ForegroundColor Cyan
