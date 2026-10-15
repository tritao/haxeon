# Haxeon platform package

This package owns NativeKit's Haxeon platform services bindings and managed wrappers. NativeKit owns the public C headers, native implementation, and native tests.

Managed APIs now live in `haxeon.platform.*`. Generated HXI and projection maps live in `bindings/`; managed code lives in `src/`.

The host platform package includes NativeKit's generic asynchronous HTTP interface. `NativeKitEvents` snapshots HTTP headers, progress, and completion events into managed values before releasing the native event; response bodies and headers therefore remain safe to retain. Host builds use `nativekit-net.hxi`; ABI32 builds use `nativekit-net-wasm.hxi` with NativeKit's browser fetch backend.

## Native dependency

The `vendor/nativekit` submodule pins the supported NativeKit revision. Initialize it and its native dependencies from the Haxeon repository root with `git submodule update --init --recursive vendor/nativekit`. Set `NATIVEKIT_DIR=/path/to/nativekit` to use a separate checkout. `HAXEON_DIR` may override the compiler checkout. Native libraries must be built and available on the runtime library search path; the package manifest does not build or bundle them.

## Tooling

Run tools from this package's `tools/` directory. Platform `tools/test-haxe-bindings.sh` performs ABI32/ABI64 checks and both platform and GPU runtime smoke tests. GPU `tools/check-hxi.sh` regenerates its reviewed interface; `tools/test-haxeon.sh` runs the graphical stress fixture.

Generator source labels retain their original paths to preserve reviewed HXI content during extraction.

## License

The extracted NativeKit bindings and wrappers retain their Apache License 2.0 license; see `LICENSE`.

## Transport façade

`haxeon.platform.NativeTransport` owns the managed transport façade formerly kept by RobotKit. Its TCP helpers retain
byte-stream semantics. `websocket(host, port, path, timeout, secure)` opts into NativeKit's complete-message and UTF-8 text
modes; `receiveMessage` returns null only when drained, preserves empty messages, and resizes for a complete message up to
its 4 MiB receive budget. Observe connection/terminal transport events through the owner's `NativeKitEvents`, dispose
subscriptions before closing handles, and keep one shared event pump per runtime.
