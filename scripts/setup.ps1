$ErrorActionPreference = "Stop"

$RootDir = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
cmake -P (Join-Path $RootDir "cmake/Bootstrap.cmake")
exit $LASTEXITCODE
