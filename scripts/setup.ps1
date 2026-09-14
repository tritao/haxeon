$ErrorActionPreference = "Stop"

$RootDir = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$CygwinBash = "C:\tools\cygwin\bin\bash.exe"
if (-not (Test-Path $CygwinBash)) {
	throw "Cygwin bash is required to build the pinned Windows libffi dependency"
}

$env:HAXEON_WORKSPACE = $RootDir
& $CygwinBash --login --norc -eo pipefail -o igncr -c `
	'cd "$(cygpath -u "$HAXEON_WORKSPACE")" && ./scripts/build-libffi.sh --msvc'
if ($LASTEXITCODE -ne 0) {
	exit $LASTEXITCODE
}

$LibffiBin = Join-Path $RootDir ".tools/libffi/bin"
$env:PATH = "$LibffiBin;$env:PATH"
if ($env:GITHUB_PATH) {
	Add-Content -Path $env:GITHUB_PATH -Value $LibffiBin -Encoding utf8
}

cmake -P (Join-Path $RootDir "cmake/Bootstrap.cmake")
exit $LASTEXITCODE
