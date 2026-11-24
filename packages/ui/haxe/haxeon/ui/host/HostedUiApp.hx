package haxeon.ui.host;

import haxe.io.Bytes;
import haxeon.gpu.SurfaceOptions;
import haxeon.platform.App;
import haxeon.platform.FrameTick;
import haxeon.platform.NativeKitError;
import haxeon.platform.Runtime;
import haxeon.platform.Surface;
import haxeon.platform.SurfaceFrame;
import haxeon.platform.WindowOptions;
import haxeon.platform.event.EventSubscription;
import haxeon.ui.FontCollection;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes;
import haxeon.ui.host.UiHostSession.UiHostLifecycle;

/** Adapts a UI application to the platform's acquired-frame loop. */
class HostedUiApp implements App {
	final options:UiHostOptions;
	final create:UiHostContext->UiApplication;
	final surface:Surface;
	final fonts:FontCollection;
	final session:UiHostSession;
	final context:DesktopUiHostContext;
	final ui:UiHostRuntime;
	var resize:EventSubscription;
	var resources:EventSubscription;
	var pending:UiHostPendingResources<Int>;
	final loaded:Array<Null<Bytes>> = [];
	var remaining = 0;
	var readyToStart = false;
	var logicalWidth:Int;
	var logicalHeight:Int;
	var animationAt = -1.0;
	var caretAt = -1.0;
	#if !wasm
	var recorder:DesktopFrameRecorder;
	var script:ScriptedInput;
	var capturePending = false;
	var captureToken:Null<haxe.Int64>;
	var captureSubscription:EventSubscription;
	var traceSubscription:EventSubscription;
	#end

	public function new(runtime:Runtime, options:UiHostOptions, create:UiHostContext->UiApplication) {
		this.options = options;
		this.create = create;
		logicalWidth = options.width;
		logicalHeight = options.height;
		var windowOptions = new WindowOptions(options.width, options.height);
		windowOptions.title = options.title;
		windowOptions.flags = WindowFlags.Resizable;
		var window = runtime.createWindow(windowOptions);
		surface = window.createSurface(SurfaceOptions.forGpu(options.width, options.height));
		surface.setFrameMode(SurfaceFrameMode.OnDemand);
		fonts = FontCollection.create();
		var initialized = false;
		defer if (!initialized) dispose();
		fonts.addDefaultFonts();
		session = new UiHostSession(function() {});
		context = new DesktopUiHostContext(fonts, runtime.events, window.nativeHandle(), surface.nativeHandle(),
			session.stop, surface.requestFrame);
		ui = new UiHostRuntime(session, context, window.nativeHandle(), surface.nativeHandle(), options.width,
			options.height);

		#if wasm
		NativeKitUIBrowser.nkui_browser_pointer_events(context.window.rawValue(), 1);
		var assets = options.fonts;
		if (assets != null && assets.length > 0) {
			session.transition(UiHostLifecycle.LoadingResources);
			pending = new UiHostPendingResources();
			remaining = assets.length;
			resources = runtime.events.listen(function(event) switch event {
				case Raw(kind, _, id, result, _, _, data) if (kind == EventKind.ResourceDataComplete):
					var index = pending.resolve(Std.string(id));
					if (index != null) {
						if (result != Result.Ok || data.length == 0) {
							ui.fail("font-load",
								new NativeKitError(result == Result.Ok ? Result.ErrorInvalidArgument : result,
								"UiHost.loadFont", assets[index].uri));
						} else {
							loaded[index] = data;
							remaining--;
							if (remaining == 0) {
								for (i in 0...assets.length)
									fonts.addData(assets[i].name, loaded[i], assets[i].family);
								startApplication();
							}
						}
					}
				case _:
			});
			for (i in 0...assets.length) {
				var asset = assets[i];
				var request = new ResourceValue();
				request.set_struct_size(ResourceValue.byteSize());
				request.set_flags(ResourceFlags.Readable);
				request.set_uri(asset.uri);
				request.set_mime_type("font/ttf");
				request.set_display_name(asset.name);
				pending.add(Std.string(NativeKit.nk_resource_load_async_checked(request)), i);
			}
		}
		#end

		#if !wasm
		var desktop = new DesktopUiHostOptions(options).withArguments(Sys.args());
		desktop.validate();
		recorder = new DesktopFrameRecorder(desktop);
		traceSubscription = recorder.attach(runtime.events, context.window);
		if (desktop.inputScriptPath != null)
			script = new ScriptedInput(desktop.inputScriptPath);
		captureSubscription = surface.onFrameComplete(function(token, result) {
			if (captureToken == token) {
				captureToken = null;
				capturePending = result == Result.Ok;
			}
		});
		#end
		window.onClose(context.requestClose);
		resize = surface.onResize(function(width, height, _, _) {
			if (width > 0 && height > 0) {
				logicalWidth = width;
				logicalHeight = height;
				surface.requestFrame();
			}
		});
		runtime.drive(surface, null, poll);
		initialized = true;
	}

	public function ready():Void {
		var size = NativeKit.nk_window_get_size(context.window);
		if (size.status == Result.Ok && size.out_width > 0 && size.out_height > 0) {
			logicalWidth = size.out_width;
			logicalHeight = size.out_height;
		}
		readyToStart = true;
		startApplication();
	}

	function startApplication():Void {
		if (!readyToStart || remaining != 0 || !session.isActive() || session.state == UiHostLifecycle.Running)
			return;
		ui.start(create, true);
		surface.requestFrame();
	}

	public function frame(tick:FrameTick, acquired:SurfaceFrame):Void {
		if (session.state != UiHostLifecycle.Running) return;
		ui.setScale(tick.width / logicalWidth);
		ui.resize(logicalWidth, logicalHeight, tick.width, tick.height);
		ui.setSurfaceReady(true);
		var now = Sys.time();
		#if !wasm
		recorder.begin(surface, tick.timeSeconds, 0, -1, -1, 0);
		ui.measureFrameTimings = recorder.enabled;
		#end
		var rendered = ui.render(tick.timeSeconds, false, acquired);
		#if !wasm
		recorder.submitted(rendered);
		recorder.endRender();
		#end
		if (!rendered) return;
		var onFrameRendered = options.onFrameRendered;
		if (onFrameRendered != null) onFrameRendered();
		var appContext = ui.app().context();
		var animationWait = appContext.animationWaitSeconds();
		animationAt = animationWait < 0 ? -1.0 : now + animationWait;
		caretAt = appContext.textInput.takeCaretFrameAt();
		#if !wasm
		if (recorder.ready() && script != null) script.start(now);
		recorder.finishFrame(ui, false, recorder.finishedAt());
		if (recorder.reachedFrameLimit() || (recorder.elapsed() && (script == null || script.complete)))
			captureToken = acquired.token();
		else if (recorder.needsFrames()) surface.requestFrame();
		#end
		if (appContext.needsAnimationFrame) surface.requestFrame();
	}

	public function afterFrame():Void {}

	function poll():Null<Float> {
		var onPoll = context.onPoll;
		if (onPoll != null) onPoll();
		var now = Sys.time();
		#if !wasm
		if (capturePending) {
			capturePending = false;
			if (recorder.enabled) recorder.write(context.window, ui);
			session.stop();
			return null;
		}
		var nextInput:Null<Float> = null;
		if (script != null) {
			var active = ScriptedInput.backHandler;
			defer ScriptedInput.backHandler = active;
			ScriptedInput.backHandler = context.handleBack;
			while (script.tick(now, context.events, context.window, function(label) {}, function(at) {},
				function(seconds) {})) {}
			nextInput = script.secondsUntilNext(now);
		}
		if (recorder.elapsed() && (script == null || script.complete)) surface.requestFrame();
		#else
		var nextInput:Null<Float> = null;
		#end
		if ((animationAt >= 0.0 && now >= animationAt) || (caretAt >= 0.0 && now >= caretAt))
			surface.requestFrame();
		var nextFrame = animationAt >= 0.0 && caretAt >= 0.0 ? Math.min(animationAt, caretAt)
			: Math.max(animationAt, caretAt);
		var wake = onPoll != null ? 1.0 / 60.0 : 0.1;
		if (nextInput != null) wake = Math.min(wake, nextInput);
		if (nextFrame >= 0.0) wake = Math.min(wake, Math.max(0.0, nextFrame - now));
		return wake;
	}

	public function shouldQuit():Bool {
		var error = session.error;
		if (error != null) {
			var notify = options.onError;
			defer if (notify != null) notify(error);
			throw error;
		}
		return !session.isActive();
	}

	public function dispose():Void {
		defer fonts.dispose();
		defer if (ui != null) ui.dispose();
		defer if (pending != null) pending.cancel();
		defer if (resources != null) resources.dispose();
		defer if (resize != null) resize.dispose();
		#if !wasm
		defer if (captureSubscription != null) captureSubscription.dispose();
		defer if (traceSubscription != null) traceSubscription.dispose();
		if (recorder != null) recorder.stopCensus();
		#else
		if (context != null) NativeKitUIBrowser.nkui_browser_pointer_events(context.window.rawValue(), 0);
		#end
	}
}
