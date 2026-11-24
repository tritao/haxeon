# Haxeon VS Code extension

The extension provides Haxe language support, source debugging, and a realtime profiler. Put `haxeon` on
`PATH` or set `haxeon.server.path` to the CLI executable. The language server uses `haxeon lsp` by default.

## Debug a project

1. Open a folder containing `haxeon.toml` and set a breakpoint in a `.hx` file.
2. Press **F5**. If VS Code asks for a debugger, select **Haxeon**.

The extension builds the host development target and starts either the desktop app runner or the HashLink VM
with the debugger waiting. The bundled adapter supports source breakpoints, stepping, call stacks, and variables.
The adapter runs on x64 Linux, Windows, and Intel macOS. On macOS, the target and debugger need the OS permissions
for native debugging.

Use the **Haxeon: Launch** configuration snippet for a project in a subdirectory (set `cwd`) or to pass
program `args`. To attach locally, start the project with `haxeon run --debug-port 6112` and select a
**Haxeon: Attach** configuration with the same port. Set `program` if the running build's bytecode is somewhere
other than `build/host/main.hl` relative to `cwd`. Set `sourceRoots` for sources outside the default `src` directory.
Attaching requires permission to debug the already running process. Linux ptrace restrictions can prevent this even when F5 launch works.

## Build the extension from source

From this directory, run `npm ci && npm run build`. The build uses the checkout's bootstrapped Haxe compiler
or Haxe 4.3.7 on `PATH` and fetches the pinned Haxe dependencies through Git. Press F5 from this directory
to run the Extension Development Host. The build applies `scripts/adapter.patch` to temporary copies of the
vendored debugger and bytecode reader. VSIX packaging includes the compiled adapter and native bindings.

## Profile a running program

1. Start the target with `hl --diagnostics PORT application.hl`.
2. Set `haxeon.profiler.port`, then run **Haxeon: Open Realtime Profiler**.

Diagnostics binds to loopback by default. For authenticated profiling, set
`HL_DIAGNOSTICS_TOKEN` in the target environment and run **Haxeon: Set
Diagnostics Token** to store the matching value in VS Code SecretStorage. Public
binding additionally requires `--diagnostics-public` and a configured token.
The token authenticates but does not encrypt HLDI traffic; use an SSH tunnel or
another encrypted transport for profiling across untrusted networks.

The panel includes connect/start/pause/reset controls, sampling-rate selection,
an incremental call tree and flame graph, transport health, hot-reload revision
markers and filtering, and click-to-source navigation.
After a transport failure it reconnects with exponential backoff and marks the
resulting sample gap rather than silently joining unrelated timelines.
