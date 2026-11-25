# Project CLI and builds

The project CLI creates projects with a `haxeon.toml` manifest
([MANIFEST.md](MANIFEST.md)), builds desktop HashLink programs, Android APKs and
experimental web bundles, and launches desktop and Android apps. It runs on
Unix-like systems and Windows.

The examples assume `haxeon` is on PATH from an installed [release](RELEASES.md).

## Help

`haxeon --help` lists the commands by task. Use `haxeon help COMMAND` to see a command's options.
For example, `haxeon help build`, `haxeon build --help` and `haxeon build -h` show the build options.

A command line that starts with an `.hxml` file or one of Haxe's options (`-cp`, `-main`,
`--hl`, `-D`, ...) is built as Haxe would build it. See [Haxe command lines](cli/build-run.md#filehxml).

## Command groups

- [Project](cli/project.md) — Create, migrate and clean projects, check the installation, and list platforms and devices.
- [Build & run](cli/build-run.md) — Build, check, describe and run projects, scripts, Haxe command lines and workspaces.
- [Test & quality](cli/test-quality.md) — Run tests, format sources and check lint rules.
- [Packages](cli/packages.md) — Add, resolve, inspect, publish and validate packages.
- [Tools](cli/tools.md) — Use the language server, FFI tools, diagnostics and checkout commands.

## Project manifests

A project may keep a `haxeon.json` instead, with the same keys ([MANIFEST.md](MANIFEST.md) lists them and shows both
forms); every command reads either, and a directory with both is a usage error that names both.

## Build modes

Desktop and Wasm builds default to `development`, retaining metadata for
debuggers and other development tools. Use `--build-mode release` to build a native executable
for a host console project or desktop app, or to build a Wasm artifact for distribution.
Use development mode for `run --watch` with a desktop app or host console project.
The Android debug host uses development metadata for live patching. Release HashLink
modules retain function names and line tables for profiler output and stack
traces, and omit opcode spans and embedded source snapshots. The compiler CLI
accepts the equivalent `--build-mode=release` or `--build-mode=development`.

Module metadata mode is independent of native optimization. Host project builds
keep optimized `Release` native libraries in both modes, including the default
development mode and live rebuilds.

## Verbosity

A build says little by default: a line when it starts, its diagnostics, and a line
when it ends.

```text
Building my-app (host, development)…
✔ build/host/main.hl (0.4 s)
```

`-v LEVEL` (`--verbosity LEVEL`) chooses how much `build` and `run` print. Each level
prints what the ones before it print, and more:

| Level | Prints |
|---|---|
| `quiet` (`q`) | diagnostics only |
| `minimal` (`m`) | the default: the first and last line above |
| `normal` (`n`) | each action as it starts or is found up to date (`[id] clean (fingerprint match)`), and the compiler's progress (`reusing compiler session`, `compiled N source files -> PATH`) |
| `detailed` (`d`) | the compiler worker's costs (`compiler: 12 ms, 3 functions retyped`, `worker allocations: ...`) and the FFI files it loads |
| `diagnostic` (`diag`) | the compiler's phase, IR pass and allocation reports |

The compiler takes the same levels as `--verbosity=LEVEL` (default `normal`); scripts that
read its reports pass `--verbosity=diagnostic`. A self-hosted build (`--self-hosted`)
runs the committed bootstrap compiler, which prints what it always printed.

## Diagnostics

Diagnostics go to standard error, each with its file relative to the directory the
command was run from, the line it concerns and a caret under the code, and end with
how many errors there were:

```text
src/Main.hx:2:14: error[E1002]: Type mismatch for local "x": expected Int, got String
 2 |     var x:Int = "a";
   |                 ^^^

1 error
```

They are coloured on a terminal: `--color=auto|always|never` (default `auto`, which
also honours `NO_COLOR` and `TERM=dumb`). `--diagnostic-format=short` prints the one
line each that tools and tests read instead, `Main.hx:2:14: E1002: ...`, with the path
under its source root. That is the compiler's own default (`--diagnostic-format=`,
`--color=` and `--diagnostic-directory=` select the full format there); the language
server reports diagnostics through the protocol, unchanged.
See the [error code reference](ERRORS.md) for what each code means and how to fix it.

## Exit codes

A mistyped command gets one line naming the closest command and exits with status 2.

A value the CLI does not take is reported with the values it does, as in `Unknown
target "solaris". Valid: host, android, wasm32, ...`. Every command exits with 0 when it
succeeds, 1 when a build, a test or another step fails, 2 for a usage error (an unknown
command or option, a missing or invalid value) and 70 for an internal error, which is a
bug in Haxeon. The compiler run directly takes each valued option as `--name=value` or
`--name value`, and exits with 2 for a usage error too.
