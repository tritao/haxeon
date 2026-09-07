# Haxeon VS Code extension

This extension starts the Haxeon language server and provides a realtime
profiler panel backed by the HashLink Diagnostics Interface.

1. Run `npm install && npm run compile` in this directory.
2. Make `haxeon-lsp` available on `PATH`, or set `haxeon.server.path`.
3. Start the target with `hl --diagnostics PORT application.hl`.
4. Set `haxeon.profiler.port`, then run **Haxeon: Open Realtime Profiler**.

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
