$ErrorActionPreference = "Stop"

$RepoDir = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
$ProjectDir = Join-Path $env:TEMP ("haxeon-cli-" + [Guid]::NewGuid().ToString("N"))
$AndroidProjectDir = Join-Path $ProjectDir "android-project"
$Cli = Join-Path $RepoDir "scripts/haxeon.cmd"

try {
    New-Item -ItemType Directory -Path $ProjectDir | Out-Null
    Push-Location $ProjectDir
    & $Cli create . --template console
    if ($LASTEXITCODE -ne 0) { throw "haxeon create failed with $LASTEXITCODE" }
    $Manifest = Get-Content -Raw -Path "haxeon.toml"
    if ($Manifest -notmatch '(?m)^\[package\]\s*\r?\nname\s*=\s*"[^"]+"') {
        throw "haxeon create did not write a non-empty package name"
    }

    Set-Content -NoNewline -Path "src/Main.hx" -Value "function main():Int return Sys.args().length == 1 ? 42 : 43;`n"
    & $Cli doctor
    if ($LASTEXITCODE -ne 0) { throw "haxeon doctor failed with $LASTEXITCODE" }
    & $Cli platforms
    if ($LASTEXITCODE -ne 0) { throw "haxeon platforms failed with $LASTEXITCODE" }
    & $Cli build
    if ($LASTEXITCODE -ne 0) { throw "haxeon build failed with $LASTEXITCODE" }
    if (-not (Test-Path "build/host/main.hl")) { throw "host output was not created" }
    & $Cli build --target wasm32
    if ($LASTEXITCODE -ne 0) { throw "wasm32 build failed with $LASTEXITCODE" }
    if (-not (Test-Path "build/wasm32/main.wasm")) { throw "wasm32 output was not created" }

    New-Item -ItemType Directory -Path $AndroidProjectDir | Out-Null
    Push-Location $AndroidProjectDir
    & $Cli create . --platforms android
    if ($LASTEXITCODE -ne 0) { throw "Android haxeon create failed with $LASTEXITCODE" }
    Pop-Location
    # Preparing the generated assets needs no Android toolchain.
    $Generated = Join-Path $AndroidProjectDir "build/generated/android"
    & $Cli build --target android --project $AndroidProjectDir --gradle-inputs (Join-Path $Generated "inputs.properties")
    if ($LASTEXITCODE -ne 0) { throw "Android build for Gradle failed with $LASTEXITCODE" }
    foreach ($File in @("assets/app.hl", "assets/app.hli", "assets/app.entry", "assets/app.hcs", "inputs.properties", "haxeon.cmake")) {
        if (-not (Test-Path (Join-Path $Generated $File))) { throw "Android output $File was not created" }
    }

    Pop-Location
    & $Cli run --project $ProjectDir -- hello
    if ($LASTEXITCODE -ne 42) { throw "haxeon run returned $LASTEXITCODE; expected 42" }
    Write-Output "PASS: project CLI create, doctor, target listing, host run, wasm32 build, and Android asset generation"
    exit 0
} finally {
    while ((Get-Location).Path -like "$ProjectDir*") { Pop-Location }
    if (Test-Path $ProjectDir) { Remove-Item -LiteralPath $ProjectDir -Recurse -Force }
}
