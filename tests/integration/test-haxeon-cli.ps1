$ErrorActionPreference = "Stop"

$RepoDir = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
$ProjectDir = Join-Path $env:TEMP ("haxeon-cli-" + [Guid]::NewGuid().ToString("N"))
$AndroidProjectDir = Join-Path $ProjectDir "android project"
$Cli = Join-Path $RepoDir "scripts/haxeon.cmd"

try {
    New-Item -ItemType Directory -Path $ProjectDir | Out-Null
    Push-Location $ProjectDir
    & $Cli init
    if ($LASTEXITCODE -ne 0) { throw "haxeon init failed with $LASTEXITCODE" }
    $Manifest = Get-Content -Raw -Path "haxeon.toml"
    if ($Manifest -notmatch '(?m)^\[package\]\s*\r?\nname\s*=\s*"[^"]+"') {
        throw "haxeon init did not write a non-empty package name"
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
    & $Cli init --target android
    if ($LASTEXITCODE -ne 0) { throw "Android haxeon init failed with $LASTEXITCODE" }
    Pop-Location
    # What Gradle packages, as Gradle on its own asks for it: no Android SDK is needed for a project without native code.
    $AndroidInputs = Join-Path $AndroidProjectDir "gradle inputs.properties"
    & $Cli build --target android --project $AndroidProjectDir --gradle-inputs $AndroidInputs
    if ($LASTEXITCODE -ne 0) { throw "Android build for Gradle failed with $LASTEXITCODE" }
    $AndroidModule = Join-Path $AndroidProjectDir "build/android-arm64/app.hl"
    foreach ($Suffix in @("", ".hli", ".entry", ".hcs")) {
        if (-not (Test-Path "$AndroidModule$Suffix")) { throw "Android output app.hl$Suffix was not created" }
    }
    if (-not (Test-Path $AndroidInputs)) { throw "Android Gradle inputs were not described" }
    $AndroidDemoDir = Join-Path $ProjectDir "android demo"
    New-Item -ItemType Directory -Path $AndroidDemoDir | Out-Null
    Copy-Item (Join-Path $RepoDir "android/demo/haxeon.toml"), (Join-Path $RepoDir "android/demo/Main.hx") $AndroidDemoDir
    & $Cli build --target android --project (Join-Path $AndroidDemoDir "haxeon.toml") `
        --gradle-inputs (Join-Path $AndroidDemoDir "inputs.properties")
    if ($LASTEXITCODE -ne 0) { throw "Android demo build for Gradle failed with $LASTEXITCODE" }
    foreach ($Suffix in @("", ".hli", ".entry", ".hcs")) {
        if (-not (Test-Path (Join-Path $AndroidDemoDir "build/android-arm64/app.hl$Suffix"))) {
            throw "Android demo output app.hl$Suffix was not created"
        }
    }

    Pop-Location
    & $Cli run --project $ProjectDir -- hello
    if ($LASTEXITCODE -ne 42) { throw "haxeon run returned $LASTEXITCODE; expected 42" }
    Write-Output "PASS: project CLI init, doctor, target listing, host run, wasm32 build, and Android asset generation"
    exit 0
} finally {
    while ((Get-Location).Path -like "$ProjectDir*") { Pop-Location }
    if (Test-Path $ProjectDir) { Remove-Item -LiteralPath $ProjectDir -Recurse -Force }
}
