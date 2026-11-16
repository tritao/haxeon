# The Haxeon CLI on Windows, as scripts/haxeon is elsewhere: tools.HaxeonCli built to HashLink bytecode once per change of its
# inputs (out/haxeon-cli.hl), then run on the checkout-built VM. Before the native runtime is built, or with
# HAXEON_CLI_INTERPRETED=1, the pinned Haxe interprets the CLI instead, which is slower on every command.
$ErrorActionPreference = "Stop"

$RootDir = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Haxe = Join-Path $RootDir ".tools/haxe/haxe.exe"
if (-not (Test-Path $Haxe)) {
    Write-Error "Missing pinned Haxe compiler; run scripts/setup.ps1 first"
    exit 1
}

$env:HAXEON_HOME = $RootDir

# The checkout-built VM, from the path table every entry point reads.
$HashLinkDir = $null
foreach ($Line in Get-Content (Join-Path $RootDir "cmake/hashlink-output-paths.txt")) {
    $Fields = $Line.Split("=")
    if ($Fields.Length -eq 2 -and $Fields[0] -eq "windows-msvc" -and $Fields[1].Trim() -ne "") {
        $HashLinkDir = Join-Path $RootDir $Fields[1].Trim()
    }
}
$HashLink = if ($HashLinkDir) { Join-Path $HashLinkDir "hl.exe" } else { $null }

if ($env:HAXEON_CLI_INTERPRETED -eq "1" -or -not $HashLink -or -not (Test-Path $HashLink)) {
    & $Haxe --cwd $RootDir common.hxml --run tools.HaxeonCli @args
    exit $LASTEXITCODE
}
$env:HAXEON_HASHLINK_DIR = $HashLinkDir

# Rebuild the CLI when an input changes: every file of its class paths and of the pinned Haxe's standard library, this script,
# common.hxml and the Haxe binary. Sizes and modification times stand in for the content hashes scripts/haxeon takes; a checkout
# that only touches files costs one rebuild.
$Cli = Join-Path $RootDir "out/haxeon-cli.hl"
$Stamp = "$Cli.inputs"
$Inputs = @(Get-ChildItem -Recurse -File -Path (Join-Path $RootDir "src"), (Join-Path $RootDir "lib"), (Join-Path $RootDir ".tools/haxe/std"))
$Inputs += Get-Item $PSCommandPath, (Join-Path $RootDir "common.hxml"), $Haxe
$Listing = ($Inputs | Sort-Object FullName | ForEach-Object { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" }) -join "`n"
$Sha = [System.Security.Cryptography.SHA256]::Create()
$Fingerprint = [System.BitConverter]::ToString($Sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Listing)))

$Current = (Test-Path $Cli) -and (Test-Path $Stamp) -and ((Get-Content -Raw $Stamp).Trim() -eq $Fingerprint)
if (-not $Current) {
    New-Item -ItemType Directory -Force -Path (Join-Path $RootDir "out") | Out-Null
    $Temporary = "$Cli.tmp.$PID"
    # Diagnostics go to stderr: callers capture stdout (`haxeon dev tool-path ...`).
    & $Haxe --cwd $RootDir common.hxml -main tools.HaxeonCli -hl $Temporary 2>&1 | ForEach-Object { [Console]::Error.WriteLine($_) }
    if ($LASTEXITCODE -ne 0) {
        Remove-Item -Force -ErrorAction SilentlyContinue $Temporary
        exit $LASTEXITCODE
    }
    Move-Item -Force $Temporary $Cli
    Set-Content -NoNewline -Path $Stamp -Value $Fingerprint
}

$env:PATH = "$HashLinkDir;$(Join-Path $RootDir 'out');$env:PATH"
& $HashLink $Cli @args
exit $LASTEXITCODE
