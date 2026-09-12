$ErrorActionPreference = "Stop"

$RepoDir = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
$ProjectDir = Join-Path $env:TEMP ("haxeon-cli-" + [Guid]::NewGuid().ToString("N"))
$Cli = Join-Path $RepoDir "scripts/haxeon.cmd"

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

    Pop-Location
    & $Cli run --project (Join-Path $ProjectDir "haxeon.json") -- hello
    if ($LASTEXITCODE -ne 42) { throw "haxeon run returned $LASTEXITCODE; expected 42" }
    Write-Output "PASS: project CLI init, doctor, target listing, host run, and wasm32 build"
} finally {
    if ((Get-Location).Path -eq $ProjectDir) { Pop-Location }
    if (Test-Path $ProjectDir) { Remove-Item -LiteralPath $ProjectDir -Recurse -Force }
}
