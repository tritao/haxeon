# Haxeon platform package

This package owns NativeKit's Haxeon platform services bindings and managed wrappers. NativeKit owns the public C headers, native implementation, and native tests.

Managed APIs now live in `haxeon.platform.*`. Generated HXI and projection maps live in `bindings/`; managed code lives in `src/`.

The host platform package includes NativeKit's generic asynchronous HTTP interface. `EventPump` snapshots HTTP headers, progress, and completion events into managed values before releasing the native event; response bodies and headers therefore remain safe to retain. Host builds use `nativekit-net.hxi`; ABI32 builds use `nativekit-net-wasm.hxi` with NativeKit's browser fetch backend.

## Native dependency

The `vendor/nativekit` submodule pins the supported NativeKit revision. Initialize it and its native dependencies from the Haxeon repository root with `git submodule update --init --recursive vendor/nativekit`. Set `NATIVEKIT_DIR=/path/to/nativekit` to use a separate checkout. `HAXEON_DIR` may override the compiler checkout. Native libraries must be built and available on the runtime library search path; the package manifest does not build or bundle them.

## Tooling

Run tools from this package's `tools/` directory. Platform `tools/test-haxe-bindings.sh` performs ABI32/ABI64 checks and both platform and GPU runtime smoke tests. GPU `tools/check-hxi.sh` regenerates its reviewed interface; `tools/test-haxeon.sh` runs the graphical stress fixture.

Generator source labels retain their original paths to preserve reviewed HXI content during extraction.

## License

The extracted NativeKit bindings and wrappers retain their Apache License 2.0 license; see `LICENSE`.

## Transport façade

`haxeon.platform.interop.TransportInterop` owns the managed transport façade formerly kept by RobotKit. Its TCP helpers retain
byte-stream semantics. `websocket(host, port, path, timeout, secure)` opts into NativeKit's complete-message and UTF-8 text
modes; `receiveMessage` returns null only when drained, preserves empty messages, and resizes for a complete message up to
its 4 MiB receive budget. Observe connection/terminal transport events through the owner's `EventPump`, dispose
subscriptions before closing handles, and keep one shared event pump per runtime.

## Managed API and migration

Use `RuntimeOptions`, `WindowOptions`, `WindowDecorationRegion`, `SurfaceOptions`, `WebViewOptions`,
`FileDialogOptions`/`FileDialogFilter`, and `MessageDialogOptions` in application
code. These are managed values with camelCase fields; their `nativeValue()`
methods initialize generated ABI records, sizes, and API versions at the call
boundary. Native enums and flags remain shared with the generated bindings.

```haxe
import haxeon.platform.Runtime;
import haxeon.platform.WindowOptions;
import haxeon.platform.dialog.MessageDialogOptions;
import haxeon.platform.async.Outcome;

var runtime = Runtime.start();
var options = new WindowOptions(960, 640);
options.title = "Example";
var window = runtime.createWindow(options);
var dialog = new MessageDialogOptions("Continue?");
runtime.events.requests.messageDialog(window, dialog).onComplete(function(outcome) {
    switch outcome {
        case Success(button): trace(button);
        case Cancelled: trace("Cancelled");
        case Stopped: trace("Observation stopped");
        case Failure(error): trace(error.message);
    }
});
// Pump runtime.events until the application exits, then call runtime.dispose().
```

Request methods return `Future<T>`, with one terminal `Success`,
`Failure(error)`, `Cancelled`, or `Stopped` outcome. All operations share one
tracking registry; request IDs and task handles have separate key namespaces.

`canCancel()` reports whether native cancellation can currently be requested.
`cancel()` returns true when it requests native cancellation and leaves the
future pending until a terminal event. It returns false for operations without
native cancellation, completed futures, or repeated cancellation requests; it
never detaches observation. `isCancellationRequested()` reports a successful
request. A completion already in flight may win the race. A failed native
cancellation throws and leaves the future eligible for completion or retry.
Keep pumping events after requesting cancellation.

`stopObserving()` explicitly detaches tracking and settles as `Stopped`, without
cancelling native work. It returns false once the future has completed. This is
also available for operations which cannot be cancelled natively. Late native
events remain visible to event listeners but do not complete a stopped future
again. The caller still owns any native task or stream associated with the work.

Decoder exceptions become structured `Failure` outcomes. Existing `PlatformError`
instances are preserved; other decoder exceptions become `BindingError` with
kind `InvalidData`. All completion observers run even if one throws; the first
observer exception is propagated after the remaining observers run. Observer
exceptions do not replace an operation's already settled outcome.

Runtime shutdown settles outstanding managed operations as `Cancelled`, clears
request handlers and subscriptions, and rejects new work. Failed child disposal
keeps the owner alive for retry. Successful child disposal detaches its ownership
registration immediately, so a long-lived owner does not accumulate disposed
windows, surfaces, renderers, resources, or consumed builders. Adapter code using
`registerDependent()` must detach the returned registration after manual cleanup.

Interop callers can use `startNative`, `createWindowNative`,
`createSurfaceNative`, `createWebViewNative`, `setDecorationRegionsNative`, and `WebView.createNative`
with generated records. `commitResourceNative` accepts a raw resource stream.
`trackNative(id, decoder, cancelNative)` adapts a custom native request to the
same future lifecycle; the decoder returns a typed `Outcome<T>`
and the native cancellation callback is optional. `trackTask(task, decoder)`
uses the same registry and retains caller ownership of the task. The old
`*Callback`, ID-based `track`, `forget`, and `cancelDialog` APIs have been removed;
use futures, `onComplete`, `stopObserving()`, and `cancel()` instead.

Platform/audio backend failures throw `NativeKitError`, and GPU backend failures throw
`haxeon.gpu.GpuError`. Both extend `PlatformError`, exposing `domain`, `code`,
`operation`, and `diagnostic`; `NativeKitError` also preserves its typed `result`.
Codes belong to their domain and must not be compared across platform and GPU.

Managed argument, lifecycle, and event-data validation failures use `BindingError`
(domain `haxeon-bindings`). Its typed `kind` is `InvalidArgument`, `InvalidState`,
`Disposed`, or `InvalidData`; it also extends `PlatformError`. Async `Failure(error)`
uses the same error objects, preserving domain, code, operation, and diagnostic.
Native result codes are retained for backend failures, including transport errors.

## Source layout and naming

Managed runtime and window-system types live directly in `haxeon.platform`:
`Runtime`, `Window`, `Surface`, `WebView`, their `*Options` values, and the shared
error types. Other public types are grouped by responsibility:

- `async`: `Future`, `Promise`, `Outcome`, `Requests`, and `Task`.
- `event`: `PlatformEvent`, `EventPump`, and `EventSubscription`.
- `dialog`: dialog options and filters.
- `http`: copied `HttpResponse` and `HttpHeader` values.
- `input`: `TextInput`, `TextInputState`, and `TextEdit`.
- `resource`: `Resource`, `ResourceAsset`, `ResourceCache`, and `ResourceCacheLoad`.
- `interop`: `TransportInterop`, `TransportSendQueue`, and `VulkanExtensions`.

Each public type has its own matching file. `internal` contains disposal machinery
and native event decoding; it is excluded from the public API reference and is
not a supported application import surface. Small private helpers remain beside
their owner.

The former `NativeKitResource` event payload is now `resource.Resource`, the same
value accepted by resource APIs. Its constructor is
`new Resource(uri, mimeType, displayName, flags)`; the last three arguments are
optional. No conversion to a separate event resource type is required.

Managed creation parameters consistently use `Options`. Generated ABI records
retain their original names and are imported with explicit aliases where they
would collide, for example:

```haxe
import haxeon.platform.WindowOptions;
import nativekit.ffi.NativeKitTypes.WindowOptions as NativeWindowOptions;
```

Text input uses a managed state object instead of a long positional argument list:

```haxe
import haxeon.platform.input.TextInput;
import haxeon.platform.input.TextInputState;

var state = new TextInputState(text, documentLength, selectionStart, selectionEnd);
state.textStart = windowStart;
state.compositionStart = compositionStart;
state.compositionEnd = compositionEnd;
state.cursorX = cursor.x;
state.cursorY = cursor.y;
state.cursorWidth = cursor.width;
state.cursorHeight = cursor.height;
TextInput.update(surface, state);
```

A null composition range means no active composition. `nativeValue()` creates
ABI storage at the call boundary; the managed state never exposes ABI setters.
Use `updateResult` when explicitly handling unsupported platform IME backends.

This layout replaces the former `NativeKit*`/`Native*` managed names without
compatibility aliases. `NativeKitError` retains its backend-specific name because
it carries NativeKit's typed result code. All binding and backend errors share
`PlatformError` as their common base.
