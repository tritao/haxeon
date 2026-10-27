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

## Managed API and migration

Use `RuntimeOptions`, `WindowConfig`, `DecorationRegion`, `SurfaceConfig`, `WebViewConfig`,
`FileDialogConfig`/`FileDialogFilter`, and `MessageDialogConfig` in application
code. These are managed values with camelCase fields; their `nativeValue()`
methods initialize generated ABI records, sizes, and API versions at the call
boundary. Native enums and flags remain shared with the generated bindings.

```haxe
var runtime = NativeKitRuntime.start();
var options = new WindowConfig(960, 640);
options.title = "Example";
var window = runtime.createWindow(options);
var dialog = new MessageDialogConfig("Continue?");
runtime.events.requests.messageDialog(window, dialog).onComplete(function(outcome) {
    switch outcome {
        case Success(button): trace(button);
        case Cancelled: trace("Cancelled");
        case Failure(result, message): trace(message);
    }
});
// Pump runtime.events until the application exits, then call runtime.dispose().
```

Request methods return `NativeFuture<T>`, with one terminal `Success`,
`Failure`, or `Cancelled` outcome. Dialog and task `cancel()` requests native
cancellation and waits for a terminal event; a completion already in flight may
win the race. Other requests stop observation and settle locally as `Cancelled`
without stopping native work. A failed native cancellation throws and leaves the
future eligible for completion or a later cancellation attempt. Keep pumping
events after requesting native cancellation. Task decoder exceptions become
`Failure` outcomes. All completion observers run even if one throws; the first
observer exception is then propagated.

Runtime shutdown settles outstanding managed operations as `Cancelled`, clears
request handlers and subscriptions, and rejects new work. Failed child disposal
keeps the owner alive for retry. Successful child disposal detaches its ownership
registration immediately, so a long-lived owner does not accumulate disposed
windows, surfaces, renderers, resources, or consumed builders. Adapter code using
`registerDependent()` must detach the returned registration after manual cleanup.

Interop callers can use `startNative`, `createWindowNative`,
`createSurfaceNative`, `createWebViewNative`, `setDecorationRegionsNative`, and `NativeKitWebView.createNative`
with generated records. The explicit `*Callback` request methods retain raw
request IDs; `commitResourceNative` accepts a raw resource stream and returns a
future. `track(id, handler, onShutdown)` supports custom native operations; supply
`onShutdown` when the operation owns a managed completion. `forget(id)` only
removes observation and never cancels native work. It replaces the old misleading
`requests.cancel(id)` alias. Call `cancelDialog(id)` to request cancellation of a
tracked dialog while preserving its terminal completion.

Platform/audio failures throw `NativeKitError`, and GPU failures throw
`haxeon.gpu.GpuError`. Both extend `NativeError`, exposing `domain`, `code`,
`operation`, and `diagnostic`; `NativeKitError` also preserves its typed `result`.
Codes belong to their domain and must not be compared across platform and GPU.
