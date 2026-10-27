package haxeon.platform;

import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes;
import haxeon.platform.NativeKitWindow;
import haxeon.platform.NativeKitEvents;

/** Owns one initialized NativeKit generation and all windows created through it. */
class NativeKitRuntime {
	final windows = new NativeResourceRegistry();
	public final events:NativeKitEvents;
	var disposed:Bool = false;
	var disposing:Bool = false;

	private function new() {
		events = new NativeKitEvents();
	}

	public static function start(?options:RuntimeOptions):NativeKitRuntime
		return startNative((options == null ? new RuntimeOptions() : options).nativeValue());

	public function createWindow(options:WindowConfig):NativeKitWindow
		return createWindowNative(options.nativeValue());

	public static function startNative(?options:InitOptions):NativeKitRuntime {
		var configured = options;
		if (configured == null) {
			configured = new InitOptions();
			configured.set_api_version(NativeKit.nk_api_version());
		}
		NativeKit.nk_init_checked(configured);
		return new NativeKitRuntime();
	}

	public function createWindowNative(options:WindowOptions):NativeKitWindow {
		ensureLive();
		var owned = NativeKit.nk_window_create_checked(options);
		var window = new NativeKitWindow(owned);
		window.attachOwner(windows.register(window.dispose));
		return window;
	}

	/** Destroys owned children, then ends the NativeKit generation. */
	public function dispose():Void {
		if (disposed || disposing)
			return;
		disposing = true;
		try {
			windows.releaseAll();
			NativeKit.nk_shutdown();
		} catch (error:Dynamic) {
			disposing = false;
			throw error;
		}
		disposing = false;
		disposed = true;
		events.runtimeShutdown();
	}

	public function isDisposed():Bool
		return disposed;

	function ensureLive():Void {
		if (disposed || disposing)
			throw "NativeKit runtime has been disposed";
	}
}
