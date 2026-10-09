package haxeon.ui.host;

import haxeon.ui.FontCollection;
import haxeon.platform.NativeKitEvents;
import haxe.Int64;
import nativekit.ffi.NativeKit;

/** Live, platform-neutral services available to a hosted application. */
class UiHostContext {
	public final fonts:FontCollection;
	/** Present only when the desktop host has enabled custom native chrome. */
	public var windowControls:Null<WindowControls> = null;
	/** Application zoom is independent of the monitor pixel scale. */
	public var zoom(get, set):Float;
	var applicationZoom:Float = 1.0;
	@:allow(haxeon.ui.host.UiHostRuntime)
	var onZoomChanged:Null<Float->Void>;
	public final events:NativeKitEvents;
	/** An application may defer closing while it asks to save or confirm. */
	public var onCloseRequested:Null<(Void->Void)->Void> = null;
	final close:Void->Void;
	final scheduleFrame:Void->Void;
	/** Runs background work during host iterations, independently of rendering. */
	public var onPoll:Null<Void->Void> = null;
	/** True only while delivering a frame requested exclusively for caret repaint. */
	@:allow(haxeon.ui.host.UiHostRuntime)
	public var repaintOnly(default, null):Bool = false;
	public var gpuRendererId(default, null):Int = 0;

	public function new(fonts:FontCollection, events:NativeKitEvents,
			close:Void->Void, scheduleFrame:Void->Void) {
		this.fonts = fonts;
		this.events = events;
		this.close = close;
		this.scheduleFrame = scheduleFrame;
	}

	function get_zoom():Float return applicationZoom;
	function set_zoom(value:Float):Float {
		if (!Math.isFinite(value) || value <= 0) throw "Application zoom must be positive and finite";
		if (value != applicationZoom) {
			applicationZoom = value;
			if (onZoomChanged != null) onZoomChanged(value);
			requestFrame();
		}
		return applicationZoom;
	}

	public function supports(capability:Int64):Bool {
		return Int64.compare(Int64.and(NativeKit.nk_get_capabilities(), capability),
			Int64.ofInt(0)) != 0;
	}

	/** Requests another frame without prescribing how the host schedules it. */
	public function requestFrame():Void scheduleFrame();

	@:allow(haxeon.ui.host.UiHostRuntime)
	function setGpuRenderer(value:Int):Void gpuRendererId = value;

	/** Begins the application-defined close-confirmation flow. */
	public function requestClose():Void {
		if (onCloseRequested == null) close();
		else onCloseRequested(close);
	}
}
