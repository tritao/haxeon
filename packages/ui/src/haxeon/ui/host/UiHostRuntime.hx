package haxeon.ui.host;

import NativeKitUI.UiStatus;
import haxeon.ProfileCounter;
import haxeon.ProfileRecording;
import haxeon.ProfileSpan;
import haxeon.platform.Surface;
import haxeon.platform.SurfaceFrame;
import haxeon.ui.Renderer;
import haxeon.ui.UiResult.UiError;
import haxeon.ui.core.UiFrameMetrics;
import haxeon.ui.host.UiApplication;
import haxeon.ui.style.Density;
import nativekit.ffi.NativeKitTypes;

import haxeon.ui.host.UiSurfaceBinding;
/** Shared application, input, frame, and disposal ownership used by host adapters. */
class UiHostRuntime implements Disposable {
	public final session:UiHostSession;
	public var logicalWidth(get, never):Float;
	public var logicalHeight(get, never):Float;
	public var framebufferWidth(get, never):Int;
	public var framebufferHeight(get, never):Int;
	public var scale(get, never):Float;
	public var rendered(default, null):Int = 0;
	public var lastPrepareSeconds(default, null):Float = 0.0;
	public var lastApplicationSubmitSeconds(default, null):Float = 0.0;
	public var lastContextRenderSeconds(default, null):Float = 0.0;
	public var lastPrepareAllocatedBytes(default, null):Float = 0.0;
	public var lastSubmitAllocatedBytes(default, null):Float = 0.0;
	public var lastFrameAllocatedBytes(default, null):Float = 0.0;
	/** Capture-only phase timings; normal rendering does not read the clock. */
	public var measureFrameTimings:Bool = false;
	public var lastPaintSeconds(default, null):Float = 0.0;
	/** The most recent skipped frame; cleared by the next successful render. */
	public var lastRenderResourceError(default, null):Null<String> = null;
	public var surfaceReady(get, never):Bool;

	final window:WindowHandle;
	final surface:SurfaceHandle;
	final context:UiHostContext;
	var application:Null<UiApplication> = null;
	var binding:Null<UiSurfaceBinding> = null;
	var nativeSurface:Null<Surface> = null;
	var renderer:Null<Renderer> = null;
	var frame:Null<UiSurfaceFrame> = null;
	final frameState:UiHostFrameState;
	final zoomChanged:Null<Float->Void>;
	var disposed:Bool = false;
	var started:Bool = false;
	var callbackDepth:Int = 0;
	var disposeRequested:Bool = false;

	public function new(session:UiHostSession, context:UiHostContext, window:WindowHandle,
			surface:SurfaceHandle, width:Int, height:Int, ?zoomChanged:Float->Void) {
		this.session = session;
		this.context = context;
		this.window = window;
		this.surface = surface;
		this.zoomChanged = zoomChanged;
		frameState = new UiHostFrameState(width, height);
		context.onZoomChanged = applyZoom;
		frameState.setZoom(context.zoom);
	}

	function get_logicalWidth():Float return frameState.logicalWidth;
	function get_logicalHeight():Float return frameState.logicalHeight;
	function get_framebufferWidth():Int return frameState.framebufferWidth;
	function get_framebufferHeight():Int return frameState.framebufferHeight;
	function get_scale():Float return frameState.scale;
	function get_surfaceReady():Bool return frameState.surfaceAvailable;

	public function start(create:UiHostContext->UiApplication, redrawOnInput:Bool = false):Void {
		if (started || disposed || session.state == UiHostLifecycle.Failed || session.state == UiHostLifecycle.Stopping
			|| session.state == UiHostLifecycle.Stopped) {
			fail("application-start", "UI host runtime cannot be started more than once or after termination");
			return;
		}
		started = true;
		callbackDepth++;
		try {
			var created = create(context);
			if (created == null) throw "UI application factory returned null";
			if (disposeRequested || session.state != UiHostLifecycle.Starting
				&& session.state != UiHostLifecycle.LoadingResources) {
				try created.dispose() catch (error:Dynamic) session.cleanupFailed("application-dispose", error);
			} else {
				application = created;
				renderer = Renderer.create();
				var target = Surface.borrowNativeHandle(surface);
				nativeSurface = target;
				frame = new UiSurfaceFrame(target, frameState.framebufferWidth, frameState.framebufferHeight);
				created.context().density = context.touchPrimary ? Density.Touch : Density.Pointer;
				binding = UiSurfaceBinding.attachNative(created.context(), window, target, context.events,
					context.requestFrame, redrawOnInput);
				binding.setCoordinateScale(context.zoom);
				session.transition(UiHostLifecycle.Running);
			}
		} catch (error:Dynamic) {
			fail("application-start", error);
		}
		callbackDepth--;
		if (callbackDepth == 0 && disposeRequested) disposeNow();
	}

	public function resize(width:Float, height:Float, framebufferWidth:Int,
			framebufferHeight:Int):Void {
		frameState.resize(width, height, framebufferWidth, framebufferHeight);
	}

	public function setScale(value:Float):Void frameState.setScale(value);

	function applyZoom(value:Float):Void {
		if (zoomChanged != null) zoomChanged(value);
		frameState.setZoom(value);
		if (binding != null) binding.setCoordinateScale(value);
	}
	public function setSurfaceReady(value:Bool):Void frameState.setSurfaceAvailable(value);

	/** Renders at most once for the adapter's scheduling callback. */
	public function render(timeSeconds:Float, repaintOnly:Bool = false, ?acquired:SurfaceFrame):Bool {
		var frame = this.frame;
		if (disposed || session.state != UiHostLifecycle.Running || !frameState.canRender() || application == null
			|| renderer == null || frame == null)
			return false;
		var allocatedAt = AllocationProbe.now();
		try {
			callbackDepth++;
			// Include a whole animation wait when the frame ends it.
			var animationWait = application.context().animationWaitSeconds();
			var delta = frameState.nextDelta(timeSeconds, animationWait >= 0.0 ? animationWait + 0.1 : 0.1);
			frame.configure(frameState.layoutWidth, frameState.layoutHeight, framebufferWidth, framebufferHeight,
				frameState.renderScale, delta);
			var custom:Null<UiFrameApplication> = acquired != null && Std.isOfType(application, UiFrameApplication)
				? cast application : null;
			var phaseStarted = Sys.time();
			var phaseAllocated = AllocationProbe.now();
			var submitted = custom != null && custom.submitFrame(acquired, frame.dimensions, timeSeconds);
			if (submitted) {
				lastPrepareSeconds = 0.0;
				lastPrepareAllocatedBytes = 0.0;
				lastApplicationSubmitSeconds = 0.0;
				lastSubmitAllocatedBytes = 0.0;
			} else {
				{
					ProfileSpan.begin("ui.prepare");
					defer ProfileSpan.end("ui.prepare");
					context.setGpuRenderer(frame.prepare(renderer));
				}
				lastPrepareSeconds = Sys.time() - phaseStarted;
				lastPrepareAllocatedBytes = AllocationProbe.now() - phaseAllocated;
				phaseStarted = Sys.time();
				phaseAllocated = AllocationProbe.now();
				context.repaintOnly = repaintOnly;
				application.context().buildContext.environment.pixelDensity = frameState.renderScale;
				{
					ProfileSpan.begin("ui.submit");
					defer ProfileSpan.end("ui.submit");
					application.submit(frame.layout);
				}
				lastApplicationSubmitSeconds = Sys.time() - phaseStarted;
				lastSubmitAllocatedBytes = AllocationProbe.now() - phaseAllocated;
				context.repaintOnly = false;
				if (session.state != UiHostLifecycle.Running || disposeRequested) {
					callbackDepth--;
					if (callbackDepth == 0 && disposeRequested) disposeNow();
					return false;
				}
				phaseStarted = Sys.time();
				{
					ProfileSpan.begin("ui.render");
					defer ProfileSpan.end("ui.render");
					frame.render(application.context(), renderer, acquired);
				}
			}
			lastContextRenderSeconds = Sys.time() - phaseStarted;
			lastPaintSeconds = lastContextRenderSeconds;
			lastFrameAllocatedBytes = AllocationProbe.now() - allocatedAt;
			ProfileCounter.set("ui.frame.allocated_bytes", lastFrameAllocatedBytes);
			// GPU time per frame, measured only while a capture records: it costs a GPU query per frame.
			var recording = ProfileRecording.recording();
			var timedRenderer = renderer;
			if (!submitted && timedRenderer != null) {
				timedRenderer.setGpuFrameTiming(recording);
				if (recording && timedRenderer.pollGpuFrameTime())
					ProfileCounter.set("ui.frame.gpu_ns", timedRenderer.gpuFrameNanoseconds);
				if (recording) {
					// Cumulative: a capture reads the difference, and the reasons add up to the compiles.
					var reuse = timedRenderer.planReuse();
					ProfileCounter.set("ui.plan.compiles", reuse.compiles);
					ProfileCounter.set("ui.plan.reuses", reuse.reuses);
					ProfileCounter.set("ui.plan.miss.epoch", reuse.missEpoch);
					ProfileCounter.set("ui.plan.miss.frame", reuse.missFrame);
					ProfileCounter.set("ui.plan.miss.lists", reuse.missLists);
					ProfileCounter.set("ui.plan.miss.dependencies", reuse.missDependencies);
					ProfileCounter.set("ui.plan.miss.atlas", reuse.missAtlas);
					ProfileCounter.set("ui.plan.miss.unsettled", reuse.missUnsettled);
				}
			}
			lastRenderResourceError = null;
			rendered++;
			callbackDepth--;
			if (callbackDepth == 0 && disposeRequested) disposeNow();
			return true;
		} catch (error:Dynamic) {
			context.repaintOnly = false;
			if (callbackDepth > 0) callbackDepth--;
			if (Std.isOfType(error, UiError)) {
				var uiError:UiError = cast error;
				if (uiError.status == UiStatus.ErrorResourceLimit) {
					lastRenderResourceError = uiError.message;
					if (callbackDepth == 0 && disposeRequested) disposeNow();
					return false;
				}
			}
			fail("frame", error);
			if (callbackDepth == 0 && disposeRequested) disposeNow();
			return false;
		}
	}

	public function app():Null<UiApplication> return application;
	public function frameRenderer():Null<Renderer> return renderer;

	public function fail(stage:String, error:Dynamic):Void {
		session.fail(stage, error);
		dispose();
	}

	public function dispose():Void {
		if (disposed || disposeRequested) return;
		disposeRequested = true;
		if (callbackDepth > 0) return;
		disposeNow();
	}

	public function isCallbackActive():Bool return callbackDepth > 0;

	function disposeNow():Void {
		if (disposed) return;
		disposed = true;
		context.onZoomChanged = null;
		var ownedBinding = binding;
		binding = null;
		if (ownedBinding != null)
			try ownedBinding.dispose() catch (error:Dynamic) session.cleanupFailed("input-detach", error);
		var ownedApplication = application;
		application = null;
		if (ownedApplication != null)
			try ownedApplication.dispose() catch (error:Dynamic) session.cleanupFailed("application-dispose", error);
		var ownedRenderer = renderer;
		renderer = null;
		if (ownedRenderer != null)
			try ownedRenderer.dispose() catch (error:Dynamic) session.cleanupFailed("renderer-dispose", error);
		var ownedSurface = nativeSurface;
		nativeSurface = null;
		frame = null;
		if (ownedSurface != null)
			try ownedSurface.releaseBorrowed() catch (error:Dynamic) session.cleanupFailed("surface-release", error);
	}
}

/** Platform-neutral surface, viewport, scale, and frame-timing state. */
class UiHostFrameState {
	public var logicalWidth(default, null):Float;
	public var logicalHeight(default, null):Float;
	public var framebufferWidth(default, null):Int;
	public var framebufferHeight(default, null):Int;
	public var scale(default, null):Float = 1.0;
	public var zoom(default, null):Float = 1.0;
	public var layoutWidth(get, never):Float;
	public var layoutHeight(get, never):Float;
	public var renderScale(get, never):Float;
	function get_layoutWidth():Float return logicalWidth / zoom;
	function get_layoutHeight():Float return logicalHeight / zoom;
	function get_renderScale():Float return scale * zoom;
	public var surfaceAvailable(default, null):Bool = false;
	var previousTime:Float = -1.0;

	public function new(width:Int, height:Int) {
		logicalWidth = width;
		logicalHeight = height;
		framebufferWidth = width;
		framebufferHeight = height;
	}

	/** Dimension changes never imply that a native surface is available. */
	public function resize(width:Float, height:Float, framebufferWidth:Int,
			framebufferHeight:Int):Void {
		logicalWidth = width;
		logicalHeight = height;
		this.framebufferWidth = framebufferWidth;
		this.framebufferHeight = framebufferHeight;
	}

	public function setScale(value:Float):Void if (Math.isFinite(value) && value > 0.0) scale = value;
	public function setZoom(value:Float):Void if (Math.isFinite(value) && value > 0.0) zoom = value;

	public function setSurfaceAvailable(value:Bool):Void {
		if (surfaceAvailable != value) previousTime = -1.0;
		surfaceAvailable = value;
	}

	public function canRender():Bool {
		return surfaceAvailable && logicalWidth > 0.0 && logicalHeight > 0.0 && framebufferWidth > 0
			&& framebufferHeight > 0;
	}

	/** Elapsed time since the last frame, capped so a stall does not jump an animation. */
	public function nextDelta(timeSeconds:Float, maxSeconds:Float = 0.1):Float {
		var delta = previousTime < 0.0 ? 0.0 : Math.max(0.0, Math.min(maxSeconds, timeSeconds - previousTime));
		previousTime = timeSeconds;
		return delta;
	}
}

/** Cancellation-aware request table used during asynchronous host startup. */
class UiHostPendingResources<T> {
	final values:Map<String, T> = new Map();
	var active:Bool = true;
	public var remaining(default, null):Int = 0;

	public function new() {}

	public function add(key:String, value:T):Void {
		if (!active) return;
		if (!values.exists(key)) remaining++;
		values.set(key, value);
	}

	public function resolve(key:String):Null<T> {
		if (!active) return null;
		var value = values.get(key);
		if (value != null) {
			values.remove(key);
			remaining--;
		}
		return value;
	}

	public function cancel():Void {
		if (!active) return;
		active = false;
		values.clear();
		remaining = 0;
	}
}

/** Named states of a hosted application's lifetime; no numeric boundary representation. */
enum UiHostLifecycle implements Equatable {
	Starting;
	LoadingResources;
	Running;
	Stopping;
	Stopped;
	Failed;
}

/** Structured host error retained after asynchronous startup or frame failure. */
class UiHostError extends haxe.Exception {
	public final stage:String;
	public final cause:Dynamic;
	public final diagnosticStack:String;

	public function new(stage:String, cause:Dynamic) {
		super(Std.string(cause), Std.isOfType(cause, haxe.Exception) ? cast cause : null);
		this.stage = stage;
		this.cause = cause;
		this.diagnosticStack = haxe.CallStack.toString(haxe.CallStack.exceptionStack());
	}

	override public function toString():String return stage + ": " + message;
}

/** Nonblocking handle for a hosted application's complete lifetime. */
class UiHostSession implements Disposable {
	public var state(default, null):UiHostLifecycle = UiHostLifecycle.Starting;
	public var error(default, null):Null<UiHostError> = null;
	public final cleanupErrors:Array<UiHostError> = [];
	final stopCallback:Void->Void;
	var disposed:Bool = false;
	var stopNotified:Bool = false;

	public function new(stopCallback:Void->Void) this.stopCallback = stopCallback;

	@:allow(haxeon.ui.host.UiHostRuntime)
	@:allow(haxeon.ui.host.HostedUiApp)
	function transition(next:UiHostLifecycle):Void {
		if (state == next) return;
		var valid = switch (state) {
			case UiHostLifecycle.Starting:
				next == UiHostLifecycle.LoadingResources || next == UiHostLifecycle.Running
					|| next == UiHostLifecycle.Stopping || next == UiHostLifecycle.Failed;
			case UiHostLifecycle.LoadingResources:
				next == UiHostLifecycle.Running || next == UiHostLifecycle.Stopping || next == UiHostLifecycle.Failed;
			case UiHostLifecycle.Running:
				next == UiHostLifecycle.Stopping || next == UiHostLifecycle.Failed;
			case UiHostLifecycle.Stopping:
				next == UiHostLifecycle.Stopped || next == UiHostLifecycle.Failed;
			case UiHostLifecycle.Stopped, UiHostLifecycle.Failed: false;
		};
		if (!valid) throw "Invalid UI host lifecycle transition";
		state = next;
	}

	@:allow(haxeon.ui.host.UiHostRuntime)
	function fail(stage:String, cause:Dynamic):Void {
		if (error == null) error = new UiHostError(stage, cause);
		if (state != UiHostLifecycle.Stopped) state = UiHostLifecycle.Failed;
	}

	@:allow(haxeon.ui.host.UiHostRuntime)
	function cleanupFailed(stage:String, cause:Dynamic):Void
		cleanupErrors.push(new UiHostError(stage, cause));

	public function isActive():Bool return state == UiHostLifecycle.Starting
		|| state == UiHostLifecycle.LoadingResources || state == UiHostLifecycle.Running;

	/** Stops the hosted application. Browser hosts do not claim to close the tab. */
	public function stop():Void {
		if (disposed || stopNotified || state == UiHostLifecycle.Stopped || state == UiHostLifecycle.Failed) return;
		stopNotified = true;
		state = UiHostLifecycle.Stopping;
		stopCallback();
	}

	public function dispose():Void {
		if (disposed) return;
		disposed = true;
		if (state != UiHostLifecycle.Stopped && state != UiHostLifecycle.Failed)
			state = UiHostLifecycle.Stopping;
		if (!stopNotified) {
			stopNotified = true;
			stopCallback();
		}
	}
}
