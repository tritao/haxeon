package haxeon.platform;

import haxeon.platform.Window;
import haxeon.platform.WindowOptions;
import haxeon.platform.event.EventPump;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes.InitOptions;
import nativekit.ffi.NativeKitTypes.WindowOptions as NativeWindowOptions;

/** Owns one initialized NativeKit generation and all windows created through it. */
class Runtime implements Disposable {
	final windows = new DisposalRegistry();
	public final events:EventPump;
	var disposed:Bool = false;
	var disposing:Bool = false;

	var drivingSurface:Null<Surface>;
	var frameRecorder:Null<FrameRecorder>;
	var pollWork:Null<Void->Null<Float>>;

	private function new() {
		events = new EventPump();
	}

	public static function start(?options:RuntimeOptions):Runtime
		return startNative((options == null ? new RuntimeOptions() : options).nativeValue());

	public function createWindow(options:WindowOptions):Window
		return createWindowNative(options.nativeValue());

	public static function startNative(?options:InitOptions):Runtime {
		var configured = options;
		if (configured == null) {
			configured = new InitOptions();
			configured.set_api_version(NativeKit.nk_api_version());
		}
		NativeKit.nk_init_checked(configured);
		haxeon.ProfileNativeTrace.install("nativekit");
		return new Runtime();
	}

	public function createWindowNative(options:NativeWindowOptions):Window {
		ensureLive();
		var owned = NativeKit.nk_window_create_checked(options);
		var window = new Window(owned, events);
		window.attachOwner(windows.register(window.dispose));
		return window;
	}

	/** Owns the app until it quits. On web, the browser drives the registered app. */
	public static function launch(create:Runtime->App, ?options:RuntimeOptions):Void {
		#if wasm
		BrowserHost.requireIdle();
		BrowserHost.attach(openApp(create, options));
		#else
		openApp(create, options).run();
		#end
	}

	/** Opens a managed app for a host that supplies the individual ticks. */
	public static function openApp(create:Runtime->App, ?options:RuntimeOptions):AppLaunch {
		if (create == null)
			throw BindingError.invalidArgument("Runtime.openApp", "An application factory is required");
		var runtime = start(options);
		var app:Null<App> = null;
		var opened = false;
		defer if (!opened) {
			defer runtime.dispose();
			if (app != null) app.dispose();
		}
		app = create(runtime);
		var surface = runtime.drivingSurface;
		if (app == null || surface == null)
			throw BindingError.invalidArgument("Runtime.launch",
				"The application must register a frame-driving surface");
		var launch = new AppLaunch(runtime, app,
			new AppLoop(runtime.events, surface, app, runtime.frameRecorder, runtime.pollWork));
		opened = true;
		return launch;
	}

	/**
	 * Registers the surface that schedules application frames. Other windows can own their own surfaces.
	 * Optional poll work runs after native events and can return a shorter desktop wait in seconds.
	 */
	public function drive(surface:Surface, ?recorder:FrameRecorder, ?poll:Void->Null<Float>):Void {
		ensureLive();
		if (surface == null || !surface.usesEventPump(events) || drivingSurface != null)
			throw BindingError.invalidArgument("Runtime.drive", "An unused frame driver from this runtime is required");
		drivingSurface = surface;
		frameRecorder = recorder;
		pollWork = poll;
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
			throw BindingError.disposed("Runtime.ensureLive", "NativeKit runtime has been disposed");
	}
}
