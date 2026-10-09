package haxeon.ui.host;

import haxeon.ui.FrameInfo;
import haxeon.ui.UiResult.UiError;
import NativeKitUI.UiStatus;
import haxeon.ui.LayoutFrame;
import haxeon.platform.NativeKitEvents;
import haxeon.platform.NativeKitSurface;
import haxeon.ui.Renderer;
import haxeon.ui.Surface;
import haxeon.ui.debug.AllocationProbe;
import nativekit.ffi.NativeKitTypes;
import haxeon.ui.core.NativeInputAdapter;

/** Shared application, input, frame, and disposal ownership used by host adapters. */
class UiHostRuntime {
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
	var input:Null<NativeInputAdapter> = null;
	var nativeSurface:Null<NativeKitSurface> = null;
	var renderer:Null<Renderer> = null;
	var frame:LayoutFrame;
	var frameInfo:FrameInfo;
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
		frame = new LayoutFrame(width, height);
		frameInfo = new FrameInfo(width, height, width, height, 1.0);
	}

	function get_logicalWidth():Float return frameState.logicalWidth;
	function get_logicalHeight():Float return frameState.logicalHeight;
	function get_framebufferWidth():Int return frameState.framebufferWidth;
	function get_framebufferHeight():Int return frameState.framebufferHeight;
	function get_scale():Float return frameState.scale;
	function get_surfaceReady():Bool return frameState.surfaceAvailable;

	public function start(create:UiHostContext->UiApplication):Void {
		if (started || disposed || session.state == UiHostLifecycle.Failed ||
			session.state == UiHostLifecycle.Stopping || session.state == UiHostLifecycle.Stopped) {
			fail("application-start", "UI host runtime cannot be started more than once or after termination");
			return;
		}
		started = true;
		callbackDepth++;
		try {
			var created = create(context);
			if (created == null) throw "UI application factory returned null";
			if (disposeRequested || session.state != UiHostLifecycle.Starting &&
				session.state != UiHostLifecycle.LoadingResources) {
				try created.dispose() catch (error:Dynamic) session.cleanupFailed("application-dispose", error);
			} else {
				application = created;
				renderer = Renderer.create();
				nativeSurface = NativeKitSurface.borrowNativeHandle(surface);
				created.context().attachPlatformSurface(nativeSurface);
				created.context().attachPlatformWindow(window);
				input = new NativeInputAdapter(created.context(), new Handle(window.rawValue()),
					new Handle(surface.rawValue()));
				input.coordinateScale = context.zoom;
				created.context().textInput.coordinateScale = context.zoom;
				created.context().platformCoordinateScale = context.zoom;
				input.attach(context.events);
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
		if (input != null) input.coordinateScale = value;
		if (application != null) {
			application.context().textInput.coordinateScale = value;
			application.context().platformCoordinateScale = value;
		}
	}
	public function setSurfaceReady(value:Bool):Void frameState.setSurfaceAvailable(value);

	/** Renders at most once for the adapter's scheduling callback. */
	public function render(timeSeconds:Float, repaintOnly:Bool = false):Bool {
		if (disposed || session.state != UiHostLifecycle.Running || !frameState.canRender() ||
			application == null || renderer == null)
			return false;
		var allocatedAt = AllocationProbe.now();
		try {
			callbackDepth++;
			var phaseStarted = Sys.time();
			var phaseAllocated = AllocationProbe.now();
			var renderSurface = Surface.fromNativeHandle(surface);
			context.setGpuRenderer(renderer.prepare(renderSurface));
			lastPrepareSeconds = Sys.time() - phaseStarted;
			lastPrepareAllocatedBytes = AllocationProbe.now() - phaseAllocated;
			phaseStarted = Sys.time();
			phaseAllocated = AllocationProbe.now();
			frame.setViewport(frameState.layoutWidth, frameState.layoutHeight);
			frame.deltaSeconds = frameState.nextDelta(timeSeconds);
			frameInfo.set(frameState.layoutWidth, frameState.layoutHeight, framebufferWidth, framebufferHeight, frameState.renderScale);
			context.repaintOnly = repaintOnly;
			application.submit(frame);
			lastApplicationSubmitSeconds = Sys.time() - phaseStarted;
			lastSubmitAllocatedBytes = AllocationProbe.now() - phaseAllocated;
			context.repaintOnly = false;
			if (session.state != UiHostLifecycle.Running || disposeRequested) {
				callbackDepth--;
				if (callbackDepth == 0 && disposeRequested) disposeNow();
				return false;
			}
			phaseStarted = Sys.time();
			application.context().render(renderer, renderSurface, frameInfo);
			lastContextRenderSeconds = Sys.time() - phaseStarted;
			lastPaintSeconds = lastContextRenderSeconds;
			lastFrameAllocatedBytes = AllocationProbe.now() - allocatedAt;
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
		var ownedInput = input;
		input = null;
		if (ownedInput != null)
			try ownedInput.detach() catch (error:Dynamic) session.cleanupFailed("input-detach", error);
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
		if (ownedSurface != null)
			try ownedSurface.releaseBorrowed() catch (error:Dynamic) session.cleanupFailed("surface-release", error);
	}
}
