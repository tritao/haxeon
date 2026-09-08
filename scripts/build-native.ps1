$ErrorActionPreference = "Stop"

$RootDir = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Preset = if ($env:HAXEON_CMAKE_PRESET) { $env:HAXEON_CMAKE_PRESET } else { "windows-msvc" }

cmake --preset $Preset -S $RootDir
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
cmake --build --preset $Preset
exit $LASTEXITCODE
