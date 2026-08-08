$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$temporary = Join-Path ([IO.Path]::GetTempPath()) ("herdr-context-" + [guid]::NewGuid().ToString("N"))
[void][IO.Directory]::CreateDirectory($temporary)

function Assert-Equal([string]$Expected, [string]$Actual, [string]$Message) {
    if ($Expected -cne $Actual) { throw "$Message`nExpected: $Expected`nActual:   $Actual" }
}

try {
    $env:FAKE_HERDR_LOG = Join-Path $temporary "herdr.log"
    $env:HERDR_BIN_PATH = Join-Path $root "tests\fixtures\fake-companion-herdr.ps1"
    $env:HERDR_PLUGIN_ID = "custom-context"
    $env:HERDR_PANE_ID = "w0:self"
    & (Join-Path $root "scripts\open-target-picker.ps1") | Out-Null

    $open = [IO.File]::ReadAllText($env:FAKE_HERDR_LOG).TrimEnd()
    Assert-Equal "argv`tplugin`tpane`topen`t--plugin`tcustom-context`t--entrypoint`ttarget-picker-windows`t--placement`tpopup`t--focus`t--target-pane`tw0:self" $open "open-target-picker.ps1 passed unexpected arguments"

    $env:FAKE_HERDR_SNAPSHOT = '{"id":"fake","result":{"snapshot":{"focused_workspace_id":"w0","workspaces":[{"workspace_id":"w0","label":"current"},{"workspace_id":"w1","label":"other"}],"tabs":[{"tab_id":"w0:t1","label":"api"},{"tab_id":"w1:t1","label":"web"}],"agents":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","agent":"claude","agent_status":"idle","cwd":"C:\\other"},{"pane_id":"w0:p2","workspace_id":"w0","tab_id":"w0:t1","agent":"codex","agent_status":"working","cwd":"C:\\current"}]}}}'
    $env:HERDR_WORKSPACE_ID = "w0"
    $env:HERDR_CONTEXT_CONFIG = Join-Path $temporary "targets"
    $env:HERDR_CONTEXT_CHOICE = "1"
    $env:HERDR_CONTEXT_CLOSE_DELAY = "0"
    & (Join-Path $root "scripts\target-picker.ps1") | Out-Null

    Assert-Equal "w0`tw0:p2" ([IO.File]::ReadAllText($env:HERDR_CONTEXT_CONFIG).Trim()) "target-picker.ps1 did not persist the ranked workspace target"
    $bytes = [IO.File]::ReadAllBytes($env:HERDR_CONTEXT_CONFIG)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw "target-picker.ps1 wrote a UTF-8 BOM"
    }

    $manifest = [IO.File]::ReadAllText((Join-Path $root "herdr-plugin.toml"))
    foreach ($declaration in @('platforms = ["linux", "macos", "windows"]', 'id = "pin-target-windows"', 'id = "target-picker-windows"')) {
        if (-not $manifest.Contains($declaration)) { throw "target picker manifest is missing $declaration" }
    }
    Write-Output "ok - Windows companion picker scripts"
} finally {
    Remove-Item -Recurse -Force $temporary -ErrorAction SilentlyContinue
    foreach ($name in @("FAKE_HERDR_LOG", "FAKE_HERDR_SNAPSHOT", "HERDR_BIN_PATH", "HERDR_PLUGIN_ID", "HERDR_PANE_ID", "HERDR_WORKSPACE_ID", "HERDR_CONTEXT_CONFIG", "HERDR_CONTEXT_CHOICE", "HERDR_CONTEXT_CLOSE_DELAY")) {
        [Environment]::SetEnvironmentVariable($name, $null)
    }
}
