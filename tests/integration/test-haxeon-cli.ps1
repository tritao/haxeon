$ErrorActionPreference = "Stop"

$RepoDir = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
$ProjectDir = Join-Path $env:TEMP ("haxeon-cli-" + [Guid]::NewGuid().ToString("N"))
$AndroidProjectDir = Join-Path $ProjectDir "android project"
$Cli = Join-Path $RepoDir "scripts/haxeon.cmd"
$Haxe = Join-Path $RepoDir ".tools/haxe/haxe.exe"

try {
    New-Item -ItemType Directory -Path $ProjectDir | Out-Null
    Push-Location $ProjectDir
    & $Cli init
    if ($LASTEXITCODE -ne 0) { throw "haxeon init failed with $LASTEXITCODE" }

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
    $AndroidAsset = Join-Path $AndroidProjectDir "build/app.hl"
    & $Haxe --cwd $RepoDir -cp (Join-Path $RepoDir "src") --run tools.AndroidBuild --project `
        (Join-Path $AndroidProjectDir "haxeon.json") $AndroidAsset
    if ($LASTEXITCODE -ne 0) { throw "Android asset generation failed with $LASTEXITCODE" }
    foreach ($Artifact in @("app.hl", "app.hli", "app.entry", "app.hcs")) {
        if (-not (Test-Path (Join-Path (Split-Path $AndroidAsset) $Artifact))) {
            throw "Android asset $Artifact was not created"
        }
    }
    $AndroidDemoDir = Join-Path $ProjectDir "android demo"
    $AndroidDemoAsset = Join-Path $AndroidDemoDir "app.hl"
    & $Haxe --cwd $RepoDir -cp (Join-Path $RepoDir "src") --run tools.AndroidBuild `
        (Join-Path $RepoDir "android/demo/Main.hx") $AndroidDemoAsset
    if ($LASTEXITCODE -ne 0) { throw "legacy Android asset generation failed with $LASTEXITCODE" }
    foreach ($Artifact in @("app.hl", "app.hli", "app.entry", "app.hcs")) {
        if (-not (Test-Path (Join-Path $AndroidDemoDir $Artifact))) {
            throw "legacy Android asset $Artifact was not created"
        }
    }

    Pop-Location
    & $Cli run --project (Join-Path $ProjectDir "haxeon.json") -- hello
    if ($LASTEXITCODE -ne 42) { throw "haxeon run returned $LASTEXITCODE; expected 42" }
    Write-Output "PASS: project CLI init, doctor, target listing, host run, wasm32 build, and Android asset generation"
} finally {
    while ((Get-Location).Path -like "$ProjectDir*") { Pop-Location }
    if (Test-Path $ProjectDir) { Remove-Item -LiteralPath $ProjectDir -Recurse -Force }
}
