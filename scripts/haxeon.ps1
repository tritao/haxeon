$ErrorActionPreference = "Stop"

$RootDir = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Haxe = Join-Path $RootDir ".tools/haxe/haxe.exe"
if (-not (Test-Path $Haxe)) {
    Write-Error "Missing pinned Haxe compiler; run scripts/bootstrap-tools.sh first"
    exit 1
}

$env:HAXEON_HOME = $RootDir
& $Haxe -cp (Join-Path $RootDir "src") --run tools.HaxeonCli @args
exit $LASTEXITCODE
