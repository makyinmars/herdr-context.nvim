$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$herdr = if ($env:HERDR_BIN_PATH) { $env:HERDR_BIN_PATH } else { "herdr" }
$pluginId = if ($env:HERDR_PLUGIN_ID) { $env:HERDR_PLUGIN_ID } else { "herdr-context" }
$commandArgs = @(
    "plugin", "pane", "open",
    "--plugin", $pluginId,
    "--entrypoint", "target-picker-windows",
    "--placement", "popup",
    "--focus"
)
if ($env:HERDR_PANE_ID) {
    $commandArgs += @("--target-pane", $env:HERDR_PANE_ID)
}

& $herdr @commandArgs
exit $LASTEXITCODE
