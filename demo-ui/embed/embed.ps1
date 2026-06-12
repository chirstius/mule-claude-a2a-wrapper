#requires -Version 5.1
<#
.SYNOPSIS  Build the demo UI and embed it into the A2A wrapper (served at the app root).
.DESCRIPTION
  1. Runs `npm run build` (-> dist/).
  2. Copies dist/ to <wrapper>/src/main/resources/dist/ (-> ${app.home}/dist at deploy).
  3. Copies a2a-ui.xml to <wrapper>/src/main/mule/ (the static-SPA serving flow).
  Then rebuild/redeploy the wrapper and browse http://<host>/ .
  TO REMOVE: delete <wrapper>/src/main/mule/a2a-ui.xml and <wrapper>/src/main/resources/dist/.
.PARAMETER Wrapper  Path to the claude-a2a-adapter project (defaults to ../../claude-a2a-adapter).
#>
[CmdletBinding()]
param([string]$Wrapper)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$uiRoot = Resolve-Path (Join-Path $here "..")
if (-not $Wrapper) { $Wrapper = Resolve-Path (Join-Path $here "..\..\claude-a2a-adapter") }
if (-not (Test-Path (Join-Path $Wrapper "pom.xml"))) { throw "wrapper not found at $Wrapper" }

# Bake the configured A2A path into the build so the UI's default endpoint is (browser host + this path).
$common = Join-Path $Wrapper "src\main\resources\config\common.yaml"
$a2aPath = "/a2a"
if (Test-Path $common) {
  $m = Select-String -Path $common -Pattern '^\s*path:\s*"([^"]+)"' | Select-Object -First 1
  if ($m) { $a2aPath = $m.Matches[0].Groups[1].Value }
}
Write-Host "==> npm run build (VITE_A2A_PATH=$a2aPath)" -ForegroundColor Cyan
Push-Location $uiRoot
try { $env:VITE_A2A_PATH = $a2aPath; npm run build }
finally { Remove-Item Env:\VITE_A2A_PATH -ErrorAction SilentlyContinue; Pop-Location }

$dist = Join-Path $uiRoot "dist"
if (-not (Test-Path (Join-Path $dist "index.html"))) { throw "build did not produce $dist\index.html" }

$target = Join-Path $Wrapper "src\main\resources\dist"
if (Test-Path $target) { Remove-Item $target -Recurse -Force }
New-Item -ItemType Directory -Force -Path $target | Out-Null
Copy-Item (Join-Path $dist "*") $target -Recurse -Force
Copy-Item (Join-Path $here "a2a-ui.xml") (Join-Path $Wrapper "src\main\mule\a2a-ui.xml") -Force

$count = (Get-ChildItem $target -Recurse -File).Count
Write-Host "==> embedded $count file(s) into $target" -ForegroundColor Green
Write-Host "    rebuild/redeploy the wrapper, then open  /" -ForegroundColor Green
