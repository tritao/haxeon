# This checkout's haxeon command on Windows, as scripts/haxeon is elsewhere: the VM running the Haxeon CLI
# (native/haxeon_main.c), built by the native build with the CLI's bytecode beside it. The two are brought up to date first,
# so an edit to the CLI's sources is in the next command; HAXEON_NATIVE_READY=1 says a caller already did that.
$ErrorActionPreference = "Stop"

$RootDir = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

# The checkout-built VM's directory, from the path table every entry point reads.
$HashLinkDir = $null
foreach ($Line in Get-Content (Join-Path $RootDir "cmake/hashlink-output-paths.txt")) {
    $Fields = $Line.Split("=")
    if ($Fields.Length -eq 2 -and $Fields[0] -eq "windows-msvc" -and $Fields[1].Trim() -ne "") {
        $HashLinkDir = Join-Path $RootDir $Fields[1].Trim()
    }
}
if (-not $HashLinkDir) {
    Write-Error "Missing the windows-msvc entry in cmake/hashlink-output-paths.txt"
    exit 1
}
$BuildDir = Join-Path $RootDir "out/cmake/windows-msvc"
$Haxeon = Join-Path $HashLinkDir "haxeon.exe"

if ($env:HAXEON_NATIVE_READY -ne "1") {
    if (-not (Test-Path (Join-Path $BuildDir "CMakeCache.txt"))) {
        Write-Error "No native build in $BuildDir; run scripts/setup.ps1 and scripts/build-native.ps1 first"
        exit 1
    }
    # Diagnostics go to stderr only on failure: callers capture stdout (`haxeon dev tool-path ...`).
    $Log = & cmake --build $BuildDir --target haxeon-command 2>&1
    if ($LASTEXITCODE -ne 0) {
        $Log | ForEach-Object { [Console]::Error.WriteLine($_) }
        exit $LASTEXITCODE
    }
}
# Test libraries that the programs the CLI runs load by name.
$env:PATH = "$(Join-Path $RootDir 'out');$env:PATH"
& $Haxeon @args
exit $LASTEXITCODE
