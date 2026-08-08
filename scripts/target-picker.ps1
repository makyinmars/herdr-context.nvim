$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Get-Value {
    param($Object, [string]$Name, $Fallback = $null)
    if ($null -eq $Object) { return $Fallback }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value -or $property.Value -eq "") { return $Fallback }
    return $property.Value
}

$herdr = if ($env:HERDR_BIN_PATH) { $env:HERDR_BIN_PATH } else { "herdr" }
$workspaceId = $env:HERDR_WORKSPACE_ID
$defaultConfig = if ($env:HERDR_PLUGIN_CONFIG_DIR) {
    $env:HERDR_PLUGIN_CONFIG_DIR
} elseif ($env:APPDATA) {
    Join-Path $env:APPDATA "herdr\plugins\config\herdr-context"
} else {
    Join-Path $HOME ".config\herdr\plugins\config\herdr-context"
}
$configFile = if ($env:HERDR_CONTEXT_CONFIG) { $env:HERDR_CONTEXT_CONFIG } else { Join-Path $defaultConfig "targets" }

$snapshotOutput = @(& $herdr api snapshot 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "Could not read the Herdr snapshot: $($snapshotOutput -join [Environment]::NewLine)"
}
$response = ($snapshotOutput -join [Environment]::NewLine) | ConvertFrom-Json
$snapshot = Get-Value (Get-Value $response "result") "snapshot"
if ($null -eq $snapshot) {
    throw "Herdr snapshot response did not contain result.snapshot"
}

$workspaceLabels = @{}
foreach ($workspace in @(Get-Value $snapshot "workspaces" @())) {
    $workspaceLabels[[string](Get-Value $workspace "workspace_id")] = [string](Get-Value $workspace "label" "?")
}
$tabLabels = @{}
foreach ($tab in @(Get-Value $snapshot "tabs" @())) {
    $tabLabels[[string](Get-Value $tab "tab_id")] = [string](Get-Value $tab "label" "?")
}

$rows = @(
    foreach ($agentInfo in @(Get-Value $snapshot "agents" @())) {
        $agentWorkspace = [string](Get-Value $agentInfo "workspace_id")
        $tabId = [string](Get-Value $agentInfo "tab_id")
        [pscustomobject]@{
            Rank = if ($agentWorkspace -eq $workspaceId) { 0 } else { 1 }
            Status = [string](Get-Value $agentInfo "agent_status" "unknown")
            Agent = [string](Get-Value $agentInfo "agent" "agent")
            Workspace = if ($workspaceLabels.ContainsKey($agentWorkspace)) { $workspaceLabels[$agentWorkspace] } else { $agentWorkspace }
            Tab = if ($tabLabels.ContainsKey($tabId)) { $tabLabels[$tabId] } else { $tabId }
            Cwd = [string](Get-Value $agentInfo "foreground_cwd" (Get-Value $agentInfo "cwd" "?"))
            PaneId = [string](Get-Value $agentInfo "pane_id")
        }
    }
)
$rows = @($rows | Sort-Object -Property Rank, Status, Agent, PaneId)

if ($rows.Count -eq 0) {
    Write-Host "No live Herdr agents found."
    if (-not $env:HERDR_CONTEXT_CHOICE) { [void][Console]::ReadLine() }
    exit 1
}

Write-Host ""
Write-Host "Pin a default herdr-context target"
Write-Host ""
for ($index = 0; $index -lt $rows.Count; $index++) {
    $row = $rows[$index]
    $marker = switch ($row.Status) {
        "idle" { [string][char]0x25CF }
        "working" { [string][char]0x25C9 }
        "blocked" { "!" }
        "done" { [string][char]0x2713 }
        default { [string][char]0x25CB }
    }
    Write-Host ("{0,2}) {1} {2,-8} {3,-8} {4} / {5}   {6}   {7}" -f ($index + 1), $marker, $row.Status, $row.Agent, $row.Workspace, $row.Tab, $row.Cwd, $row.PaneId)
}

$choice = $env:HERDR_CONTEXT_CHOICE
if (-not $choice) {
    Write-Host ""
    Write-Host ("Choose 1-{0} (or q to cancel): " -f $rows.Count) -NoNewline
    $choice = [Console]::ReadLine()
}
if ([string]::IsNullOrWhiteSpace($choice) -or $choice -match "^[qQ]$") { exit 0 }
$number = 0
if (-not [int]::TryParse($choice, [ref]$number) -or $number -lt 1 -or $number -gt $rows.Count) {
    [Console]::Error.WriteLine("Invalid choice.")
    exit 2
}
$selected = $rows[$number - 1].PaneId

if (-not $workspaceId) {
    $workspaceId = [string](Get-Value $snapshot "focused_workspace_id")
}
if (-not $workspaceId) {
    throw "Could not determine the current workspace."
}

$parent = Split-Path -Parent $configFile
if (-not $parent) { $parent = "." }
[void][IO.Directory]::CreateDirectory($parent)
$lines = [Collections.Generic.List[string]]::new()
if ([IO.File]::Exists($configFile)) {
    foreach ($line in [IO.File]::ReadAllLines($configFile)) {
        $parts = $line -split "`t", 2
        if ($parts.Count -eq 2 -and $parts[0] -ne $workspaceId) { $lines.Add($line) }
    }
}
$lines.Add("$workspaceId`t$selected")
$temporary = Join-Path $parent ([IO.Path]::GetRandomFileName())
try {
    [IO.File]::WriteAllLines($temporary, $lines, [Text.UTF8Encoding]::new($false))
    if ([IO.File]::Exists($configFile)) {
        [IO.File]::Replace($temporary, $configFile, $null)
    } else {
        [IO.File]::Move($temporary, $configFile)
    }
} finally {
    if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
}

Write-Host ""
Write-Host "Pinned $selected for workspace $workspaceId."
$delay = 1.0
if ($env:HERDR_CONTEXT_CLOSE_DELAY) {
    [void][double]::TryParse($env:HERDR_CONTEXT_CLOSE_DELAY, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$delay)
}
if ($delay -gt 0) { Start-Sleep -Milliseconds ([int]($delay * 1000)) }
