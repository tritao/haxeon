package haxeon.ui.host;

import haxeon.platform.event.EventPump;

import haxeon.ui.FontCollection;
import haxe.Int64;
import nativekit.ffi.NativeKit;

/** Live, platform-neutral services available to a hosted application. */
class UiHostContext {
	public final fonts:FontCollection;
	/** Present only when the desktop host has enabled custom native chrome. */
	public var windowControls:Null<WindowControls> = null;
	/**
		Reads where the window is now, for the application to save; null when the host has no native window. The
		function returns null when the placement cannot be read, or is not worth keeping (minimized, fullscreen).
	**/
	public var windowPlacement:Null<Void->Null<WindowPlacement>> = null;
	/** Whether the window is the active (foreground) window; null when the host has no native window. */
	public var windowActive:Null<Void->Bool> = null;
	/** Application zoom is independent of the monitor pixel scale. */
	public var zoom(get, set):Float;
	var applicationZoom:Float = 1.0;
	@:allow(haxeon.ui.host.UiHostRuntime)
	var onZoomChanged:Null<Float->Void>;
	/** True when touch is the primary input (a phone or tablet): hover-only help such as tooltips and autofocus stays off. */
	public var touchPrimary:Bool = false;
	/**
		Where the application may draw without being covered by system bars, a display cutout or the software keyboard, as
		distances in logical pixels from each edge of the surface. All zero on a desktop window.
	**/
	public var safeLeft(default, null):Float = 0;
	public var safeTop(default, null):Float = 0;
	public var safeRight(default, null):Float = 0;
	public var safeBottom(default, null):Float = 0;
	/** The part of `safeBottom` the software keyboard covers. */
	public var keyboardBottom(default, null):Float = 0;
	/** Changes whenever the safe area does, so retained views can be rebuilt. */
	public var safeAreaRevision(default, null):Int = 0;
	/** Set by the application: handles a system Back request and returns true when it consumed it. */
	public var onBack:Null<Void->Bool> = null;
	public final events:EventPump;
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

	public function new(fonts:FontCollection, events:EventPump,
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

	/** Called by a host that has system bars or a software keyboard; `bottom` includes the keyboard. */
	public function setSafeArea(left:Float, top:Float, right:Float, bottom:Float, keyboard:Float):Void {
		if (left == safeLeft && top == safeTop && right == safeRight && bottom == safeBottom && keyboard == keyboardBottom) return;
		safeLeft = left; safeTop = top; safeRight = right; safeBottom = bottom; keyboardBottom = keyboard;
		safeAreaRevision++;
		requestFrame();
	}

	/** Gives the application the chance to consume a system Back request; false means the host should handle it. */
	public function handleBack():Bool return onBack != null && onBack();

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
