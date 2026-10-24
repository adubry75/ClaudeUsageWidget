# build.ps1 - copy src -> dist
# There is nothing to compile; this just keeps dist/ in sync with src/.
# Run after editing anything in src\, then restart the widget to pick it up.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$src  = Join-Path $root 'src'
$dist = Join-Path $root 'dist'

if (-not (Test-Path $dist)) { New-Item -ItemType Directory -Path $dist | Out-Null }

$files = 'ClaudeUsageWidget.ps1', 'Start Claude Usage Widget.vbs'

foreach ($f in $files) {
    $from = Join-Path $src $f
    if (-not (Test-Path $from)) { throw "missing source file: $from" }
    Copy-Item -LiteralPath $from -Destination (Join-Path $dist $f) -Force
    Write-Host ("  copied  {0}" -f $f)
}

# sanity: the script must stay ASCII-only (PS 5.1 reads .ps1 as ANSI without a BOM)
$bytes = [System.IO.File]::ReadAllBytes((Join-Path $dist 'ClaudeUsageWidget.ps1'))
$bad   = $bytes | Where-Object { $_ -gt 127 }
if ($bad) {
    Write-Warning "ClaudeUsageWidget.ps1 contains $($bad.Count) non-ASCII byte(s) - these turn into mojibake under PowerShell 5.1."
} else {
    Write-Host "  ascii   ok"
}

Write-Host ""
Write-Host "Built to: $dist"
Write-Host "Run:      dist\Start Claude Usage Widget.vbs"
