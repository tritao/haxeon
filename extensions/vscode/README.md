# Haxeon VS Code extension

This extension starts the Haxeon language server and provides a realtime
profiler panel backed by the HashLink Diagnostics Interface.

1. Run `npm install && npm run compile` in this directory.
2. Make `haxeon-lsp` available on `PATH`, or set `haxeon.server.path`.
3. Start the target with `hl --diagnostics PORT application.hl`.
4. Set `haxeon.profiler.port`, then run **Haxeon: Open Realtime Profiler**.

The panel includes connect/start/pause/reset controls, sampling-rate selection,
an incremental call tree and flame graph, transport health, hot-reload revision
markers and filtering, and click-to-source navigation.
