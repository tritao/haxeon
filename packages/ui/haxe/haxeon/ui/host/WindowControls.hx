package haxeon.ui.host;

import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes;
import haxeon.platform.NativeKitError;

/** Borrowed desktop window operations; close always uses the host's confirmation flow. */
class WindowControls {
	final window:WindowHandle;
	final host:UiHostContext;
	public var maximized(default, null):Bool = false;
	public var fullscreen(default, null):Bool = false;
	public var revision(default, null):Int = 0;
	public function new(window:WindowHandle, host:UiHostContext) {
		this.window = window; this.host = host;
		var state = NativeKit.nk_window_get_state(window);
		check(state.status, "window.state");
		observe(state.out_state.get_flags());
	}
	public function observe(flags:WindowStateFlags):Void {
		var nextMaximized = (flags & WindowStateFlags.Maximized) != 0;
		var nextFullscreen = (flags & WindowStateFlags.Fullscreen) != 0;
		if (maximized == nextMaximized && fullscreen == nextFullscreen) return;
		maximized = nextMaximized; fullscreen = nextFullscreen; revision++; host.requestFrame();
	}
	public function minimize():Void check(NativeKit.nk_window_minimize(window), "window.minimize");
	public function toggleMaximize():Void {
		check(maximized ? NativeKit.nk_window_restore(window) : NativeKit.nk_window_maximize(window), "window.maximize");
	}
	public function close():Void host.requestClose();
	static function check(status:Result, operation:String):Void {
		if (status != Result.Ok) throw new NativeKitError(status, operation, NativeKit.nk_last_error());
	}
}
