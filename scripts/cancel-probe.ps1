#requires -Version 5.1
<#
.SYNOPSIS  Empirically test what the A2A connector does to our running flow on tasks/cancel.
.DESCRIPTION
  Starts a long streaming turn, captures the taskId from the first SSE event, waits, then sends a
  JSON-RPC tasks/cancel for that task. Observes whether the stream stops early / reports 'canceled'
  (=> the connector interrupts our flow, so we can wire claude-interrupt) or runs on to 'completed'
  (=> no flow hook; clean cancel not supported by this connector version). Also dumps the cancel
  response and the runtime-log delta so we can see if the flow was actually interrupted.
#>
[CmdletBinding()]
param(
  [string]$Url        = "http://localhost:8081/a2a",
  [string]$RuntimeLog = "D:\mule-ee\mule-enterprise-standalone-4.11.4\logs\mule_ee.log",
  [int]$CancelAfterSeconds = 6,
  [int]$ObserveSeconds     = 25
)
$ErrorActionPreference = "Stop"
$ctx = "ctx-cancel-" + [guid]::NewGuid().ToString()
$prompt = "Write a thorough, detailed technical essay of at least 1500 words about enterprise integration patterns, event-driven architecture, idempotency, and the saga pattern. Take your time and be comprehensive."
$req = @{ jsonrpc="2.0"; id=[guid]::NewGuid().ToString(); method="message/stream"; params=@{ message=@{ role="user"; kind="message"; messageId=[guid]::NewGuid().ToString(); contextId=$ctx; parts=@(@{kind="text"; text=$prompt}) } } } | ConvertTo-Json -Depth 20 -Compress
$reqFile = [IO.Path]::GetTempFileName(); [IO.File]::WriteAllText($reqFile, $req, (New-Object Text.UTF8Encoding $false))
$streamFile = [IO.Path]::GetTempFileName()
$logStart = if (Test-Path $RuntimeLog) { (Get-Content $RuntimeLog | Measure-Object -Line).Lines } else { 0 }

Write-Host "==> starting streaming turn (ctx=$ctx)..." -ForegroundColor Cyan
$p = Start-Process curl.exe -ArgumentList "-N","-s","-X","POST",$Url,"-H","content-type: application/json","-H","accept: text/event-stream","--data","@$reqFile" -WindowStyle Hidden -PassThru -RedirectStandardOutput $streamFile

$taskId = $null
for ($i=0; $i -lt 50 -and -not $taskId; $i++) {
  Start-Sleep -Milliseconds 400
  $c = Get-Content $streamFile -Raw -ErrorAction SilentlyContinue
  if ($c -and $c -match '"result"\s*:\s*\{\s*"id"\s*:\s*"([0-9a-fA-F-]{36})"') { $taskId = $Matches[1] }
  elseif ($c -and $c -match '"taskId"\s*:\s*"([0-9a-fA-F-]{36})"') { $taskId = $Matches[1] }
}
if (-not $taskId) { Write-Warning "never saw a taskId; stream so far:"; Get-Content $streamFile; if (-not $p.HasExited){$p.Kill()}; return }
Write-Host "    taskId = $taskId" -ForegroundColor Green

Start-Sleep -Seconds $CancelAfterSeconds
$eventsBefore = (Select-String -Path $streamFile -Pattern "^event:" -AllMatches -ErrorAction SilentlyContinue | Measure-Object).Count
Write-Host "==> sending tasks/cancel after ${CancelAfterSeconds}s (SSE events so far: $eventsBefore, stream exited: $($p.HasExited))..." -ForegroundColor Cyan
$cancelReq = @{ jsonrpc="2.0"; id=[guid]::NewGuid().ToString(); method="tasks/cancel"; params=@{ id=$taskId } } | ConvertTo-Json -Depth 10
try {
  $cancelResp = Invoke-RestMethod -Method Post -Uri $Url -ContentType "application/json" -Body ([Text.Encoding]::UTF8.GetBytes($cancelReq))
  Write-Host "    cancel response: $($cancelResp | ConvertTo-Json -Depth 12 -Compress)" -ForegroundColor Yellow
} catch { Write-Warning "cancel call error: $($_.Exception.Message)" }

Start-Sleep -Seconds $ObserveSeconds
if (-not $p.HasExited) { try { $p.Kill() } catch {} }
$eventsAfter = (Select-String -Path $streamFile -Pattern "^event:" -AllMatches -ErrorAction SilentlyContinue | Measure-Object).Count
$states = (Select-String -Path $streamFile -Pattern '"state":"([a-z-]+)"' -AllMatches -ErrorAction SilentlyContinue).Matches | ForEach-Object { $_.Groups[1].Value }
Write-Host "`n==> RESULT" -ForegroundColor Cyan
Write-Host "    SSE events before cancel: $eventsBefore ; total after observation: $eventsAfter"
Write-Host "    task states seen in stream: $($states -join ' -> ')"
Write-Host "    stream tail:" -ForegroundColor DarkGray
Get-Content $streamFile -Tail 5 -ErrorAction SilentlyContinue | ForEach-Object { if ($_.Trim()) { Write-Host "      $_" -ForegroundColor DarkGray } }
Write-Host "`n    runtime log delta (flow behavior):" -ForegroundColor DarkGray
if (Test-Path $RuntimeLog) { Get-Content $RuntimeLog | Select-Object -Skip $logStart | Select-String -Pattern "claude-run-turn|Created Claude session|cancel|interrupt|ERROR|tool_use|agent.message|status_idle" -ErrorAction SilentlyContinue | Select-Object -Last 12 | ForEach-Object { Write-Host "      $($_.Line)" -ForegroundColor DarkGray } }
Remove-Item $reqFile,$streamFile -Force -ErrorAction SilentlyContinue
Write-Host "`n==> INTERPRETATION:" -ForegroundColor Cyan
Write-Host "    If states end at 'canceled' and/or events stopped right after cancel => connector INTERRUPTS the flow (cancel is wireable)."
Write-Host "    If states reach 'completed' with an answer artifact => flow ran to completion despite cancel (no hook)."
