# Haxeon platform package

This package owns NativeKit's Haxeon platform services bindings and managed wrappers. NativeKit owns the public C headers, native implementation, and native tests.

Managed APIs now live in `haxeon.platform.*`. Generated HXI and projection maps live in `bindings/`; managed code lives in `src/`.

The host platform package includes NativeKit's generic asynchronous HTTP interface. `EventPump` snapshots HTTP headers, progress, and completion events into managed values before releasing the native event; response bodies and headers therefore remain safe to retain. Native and Web builds both use `nativekit-net.hxi`; on the Web, NativeKit's browser fetch backend serves it.

## Native dependency

The `vendor/nativekit` submodule pins the supported NativeKit revision. Initialize it and its native dependencies from the Haxeon repository root with `git submodule update --init --recursive vendor/nativekit`. Set `NATIVEKIT_DIR=/path/to/nativekit` to use a separate checkout. `HAXEON_DIR` may override the compiler checkout. Native libraries must be built and available on the runtime library search path; the package manifest does not build or bundle them.

## Tooling

Run tools from this package's `tools/` directory. Platform `tools/test-haxe-bindings.sh` checks the portable bindings and runs both platform and GPU runtime smoke tests. GPU `tools/update-haxeon-hxi.sh` regenerates its reviewed interface and `--check` verifies it without writing; `tools/test-haxeon.sh` runs the graphical stress fixture.

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
import haxeon.async.Outcome;

var runtime = Runtime.start();
var options = new WindowOptions(960, 640);
options.title = "Example";
var window = runtime.createWindow(options);
var dialog = new MessageDialogOptions("Continue?");
runtime.events.requests.messageDialog(window, dialog).onComplete(function(outcome) {
    switch outcome {
        case Success(Ok(button)): trace(button);
        case Success(Err(error)): trace(error.message);
        case Cancelled: trace("Cancelled");
        case Stopped: trace("Observation stopped");
    }
});
// Pump runtime.events until the application exits, then call runtime.dispose().
```

Request methods return `Future<Result<T, NativeKitError>>`, with one terminal
`Success`, `Cancelled`, or `Stopped` outcome; a request NativeKit fails settles
`Success(Err(error))`, and one cancelled or dismissed by the user (a dialog closed
without a choice) settles `Cancelled`. A request's answer reaches only its future:
event listeners see what happens (input, windows, surfaces, web views, audio), not
the answers to what the app asked for. All operations share one
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
also available for operations which cannot be cancelled natively. A late answer
settles nothing. The caller still owns any native task or stream associated with the work.

A decoder that throws has a bug: its future settles as `Stopped`, and the
exception propagates to the event pump. All completion observers run even if one throws; the first
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
`trackNative(id, decoder, cancelNative)` adapts a custom native request, one whose
answer has no typed case and arrives as a `Raw` event, to the same future lifecycle;
the decoder returns a typed `Outcome<T>`
and the native cancellation callback is optional. `trackTask(task, decoder)`
uses the same registry and retains caller ownership of the task. The old
`*Callback`, ID-based `track`, `forget`, and `cancelDialog` APIs have been removed;
use futures, `onComplete`, `stopObserving()`, and `cancel()` instead.

NativeKit's result codes come in two kinds. A code that is the program's mistake (a bad argument or
handle, the wrong thread, a call before initialization) throws a `BindingError`, as the managed argument,
lifecycle and event-data checks do (domain `haxeon-bindings`, `kind` `InvalidArgument`, `InvalidState`,
`Disposed` or `InvalidData`). Any other code is the environment's answer, a `NativeKitError` case
(`Unsupported`, `NotFound`, `PermissionDenied`, `SurfaceLost`, `InvalidData`, `Network(NetworkError)` for an
HTTP request's or a transport's failure (`HostNotFound`, `ConnectionFailed`, `TimedOut`, ...), and
`Failed(code, reason)`): what a request's or a setup call's `Result`
holds as its `Err`, and what a `NativeKitException` carries where an API throws instead. `NativeKitStatus`
tells the two apart for the packages built on NativeKit; GPU statuses work the same way with `GpuError` and
`GpuException`. `BindingError`, `NativeKitException` and `GpuException` extend `PlatformError`, which exposes
`domain`, `code`, `operation` and `diagnostic`.

## Application loop

Create a window and surface, then call `runtime.run(surface, app)` with an
`App` implementation before dispatching surface readiness. The loop calls
`ready()` once the surface is ready and supplies a `FrameTick` and acquired
`SurfaceFrame` to `frame(tick, frame)`. Submit or present that transaction
inside the callback. The loop cancels a transaction left open.

`afterFrame()` runs after the native callback returns and before the next
frame. Use it for work such as triggering audio. Once `shouldQuit()` is true,
the loop stops drawing and drains any submitted frame. On the browser path,
call `runtime.startApp(surface, app)` and drive `loop.tick()` from
`requestAnimationFrame` until it returns `false`, then dispose the loop.

Pass a `FrameRecorder` to `run` or `startApp` to observe frame submission
and presentation timestamps. Presentation feedback depends on the backend.

Hosts that own frame scheduling can use `EventLoop` directly. Each iteration
drains up to 64 events. A desktop host can choose an idle wait after processing
the batch. A browser host can drain events without blocking.

## Window and surface events

Use `window.onKey` and `window.onClose` for window events, and `surface.onReady`,
`surface.onResize`, and `surface.onFrameComplete` for surface events. The owning
window or surface disposes its subscriptions. Dispose a subscription directly
to stop listening sooner.

`onFrameComplete` gives each submitted frame's token and a `Result<Void, NativeKitError>`:
`Err(Cancelled)` or `Err(SurfaceLost)` for a frame to draw again. A stream of signals like
this one stays an event, as do a resource cache entry's `ResourceAssetReady` and
`ResourceAssetLoadFailed` (several callers may join one load) and an audio voice's failures:
each failure in them is a `NativeKitError`, and only `Raw` still carries NativeKit's code.
A request with one answer, such as `Requests.loadResource(resource)`, settles a future
instead.

Key handlers run in registration order. A handler that returns `true` consumes
the key for subsequent handlers on that source. Attach UI input before registering
application shortcuts so focused widgets can consume keys first.
`runtime.events.listen` still observes every event, including consumed keys.

## HTTP

`HttpClient.create(events)` makes a client that answers through the event pump; it is `Err(Unsupported(...))` where
the platform has none, and `create(events, true)` admits plain HTTP, as for a local server. `client.send(request)`
returns an `HttpExchange`: `response` settles when the status and headers arrive and `complete` when the request
ends, each a `Future<Result<HttpResponse, NativeKitError>>` whose failure is usually a `Network(NetworkError)`. A
request with `streaming = true` gives its body to `onData` in pieces as it arrives instead of whole in `complete`.
`cancel()` stops the request, which settles its futures `Cancelled`; disposing the client cancels what it has in
flight.

```haxe
var request = new HttpRequest(HttpMethod.Get, "https://example.com/status");
client.send(request).complete.onComplete(function(outcome) switch outcome {
	case Success(Ok(response)): trace(response.statusCode);
	case Success(Err(error)): trace(error.describe());
	case _:
});
```

## Source layout and naming

Managed runtime and window-system types live directly in `haxeon.platform`:
`Runtime`, `Window`, `Surface`, `WebView`, their `*Options` values, and the shared
error types. Other public types are grouped by responsibility:

- `async`: `Future`, `Promise`, `Outcome`, `Requests`, and `Task`.
- `event`: `PlatformEvent`, `EventPump`, and `EventSubscription`.
- `dialog`: dialog options and filters.
- `http`: `HttpClient`, `HttpRequest`, `HttpExchange`, and the copied `HttpResponse`, `HttpHeader` and
  `HttpProgress` values.
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
compatibility aliases. `NativeKitError` and `NativeKitException` keep NativeKit's name
because they are what NativeKit answers. The thrown errors share `PlatformError` as
their common base.

## File watching

`FileWatch.create(runtime.events, listener)` watches directories with `std.fs.Watcher` on a thread of its own and
delivers what changed on the event pump's thread; it is `Err(Unsupported)` where the system cannot watch. `add(path,
recursive)` returns once the directory is watched (`NotFound`, `NotADirectory` or `PermissionDenied` when it cannot be).
`FileWatchEvent` reports `Changed(path, kind)` (`Added`, `Removed` or `Modified`), `Rescan` after changes were lost
and the registrations renewed, `Lost(path)` for a registered directory that is gone, and `Failed(error)` when one
could not be registered again. Dispose the watch before its runtime.
