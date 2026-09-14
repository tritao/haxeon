$ErrorActionPreference = "Stop"

$RootDir = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$CygwinBash = "C:\tools\cygwin\bin\bash.exe"
if (-not (Test-Path $CygwinBash)) {
	throw "Cygwin bash is required to build the pinned Windows libffi dependency"
}

$env:HAXEON_WORKSPACE = $RootDir
$BuildLibffiCommand = 'cd "$(cygpath -u "$HAXEON_WORKSPACE")" && ./scripts/build-libffi.sh'
foreach ($Mode in @("--msvc", "--msvc-debug")) {
	& $CygwinBash --login --norc -eo pipefail -o igncr -c `
		"$BuildLibffiCommand $Mode"
	if ($LASTEXITCODE -ne 0) {
		exit $LASTEXITCODE
	}
}

cmake -P (Join-Path $RootDir "cmake/Bootstrap.cmake")
exit $LASTEXITCODE
