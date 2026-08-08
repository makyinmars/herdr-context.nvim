$ErrorActionPreference = "Stop"
$global:LASTEXITCODE = 0
$encoding = [Text.UTF8Encoding]::new($false)
$line = "argv`t" + ($args -join "`t") + [Environment]::NewLine
[IO.File]::AppendAllText($env:FAKE_HERDR_LOG, $line, $encoding)

if ($args.Count -ge 2 -and $args[0] -eq "api" -and $args[1] -eq "snapshot") {
    Write-Output $env:FAKE_HERDR_SNAPSHOT
} else {
    Write-Output '{"id":"fake","result":{"type":"ok"}}'
}
