package nativekit.ui.host;

import FontCollection;
import NativeKitEventValue;
import NativeKitEvents;
import NativeKitEvents.NativeKitEventSubscription;
import haxe.io.Bytes;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitConstants;
import nativekit.ffi.NativeKitTypes;

/** Reusable nonblocking browser adapter for UiApplication. */
class BrowserUiHost {
	final options:BrowserUiHostOptions;
	final create:UiHostContext->UiApplication;
	final session:BrowserUiHostSession;
	var initialized:Bool = false;
	var stopped:Bool = false;
	var stopping:Bool = false;
	var cleanupPending:Bool = false;
	var eventDispatching:Bool = false;
	var frameRequested:Bool = true;
	var window:WindowHandle = WindowHandle.invalid();
	var surface:SurfaceHandle = SurfaceHandle.invalid();
	var events:Null<NativeKitEvents> = null;
	var eventSubscription:Null<NativeKitEventSubscription> = null;
	var fonts:Null<FontCollection> = null;
	var hostContext:Null<UiHostContext> = null;
	var runtime:Null<UiHostRuntime> = null;
	var pending:Null<UiHostPendingResources<BrowserUiFontAsset>> = null;
	var loaded:Null<Map<String, Bytes>> = null;
	var pendingCount:Int = 0;
	var logicalWidth:Float;
	var logicalHeight:Float;
	var framebufferWidth:Int = 0;
	var framebufferHeight:Int = 0;
	var pixelScale:Float = 1.0;
	var surfaceReady:Bool = false;

	public static function start(options:BrowserUiHostOptions,
			create:UiHostContext->UiApplication):BrowserUiHostSession {
		if (options == null || create == null)
			throw "Browser UI host requires options and an application factory";
		options.validate();
		var host = new BrowserUiHost(options, create);
		host.initialize();
		return host.session;
	}

	function new(options:BrowserUiHostOptions, create:UiHostContext->UiApplication) {
		this.options = options;
		this.create = create;
		logicalWidth = options.width;
		logicalHeight = options.height;
		session = new BrowserUiHostSession();
		session.attach(this);
	}

	function initialize():Void {
		try {
			var init = new InitOptions();
			init.set_api_version(NativeKit.nk_api_version());
			init.set_event_queue_capacity(options.eventQueueCapacity);
			if (NativeKit.nk_init(init) != Result.Ok)
				throw "NativeKit initialization failed: " + NativeKit.nk_last_error();
			initialized = true;

			var windowOptions = new WindowOptions();
			windowOptions.set_width(options.width);
			windowOptions.set_height(options.height);
			windowOptions.set_title(options.title);
			windowOptions.set_flags(WindowFlags.Resizable);
			windowOptions.set_owner(WindowHandle.invalid());
			windowOptions.set_kind(WindowKind.Normal);
			var createdWindow = NativeKit.nk_window_create(windowOptions);
			if (createdWindow.status != Result.Ok) throw "Browser window creation failed";
			window = createdWindow.out_window.borrow();

			var surfaceOptions = new SurfaceOptions();
			surfaceOptions.set_flags(SurfaceFlags.ForwardCompatible | SurfaceFlags.Stencil);
			surfaceOptions.set_api(GraphicsApi.OpenglEs);
			surfaceOptions.set_major_version(3);
			surfaceOptions.set_width(options.width);
			surfaceOptions.set_height(options.height);
			var createdSurface = NativeKit.nk_surface_create(new Handle(window.rawValue()), surfaceOptions);
			if (createdSurface.status != Result.Ok) throw "Browser surface creation failed";
			surface = createdSurface.out_surface.borrow();

			events = new NativeKitEvents();
			eventSubscription = events.listen(handleEvent);
			fonts = FontCollection.create();
			if (options.fonts.length == 0) finishResources();
			else loadFonts();
		} catch (error:Dynamic) {
			fail("browser-start", error);
		}
	}

	function loadFonts():Void {
		session.transition(UiHostLifecycle.LoadingResources);
		#if nativekit_bundle_web_fonts
		try {
			for (font in options.fonts) fonts.add(font.bundledPath, font.family);
			finishResources();
		} catch (error:Dynamic) fail("font-load", error);
		#else
		pending = new UiHostPendingResources();
		loaded = new Map();
		for (font in options.fonts) {
			var resource = new Resource();
			resource.set_struct_size(Resource.size());
			resource.set_flags(ResourceFlags.Readable);
			resource.set_uri(font.uri);
			resource.set_mime_type("font/ttf");
			resource.set_display_name(font.name);
			var request = NativeKit.nk_resource_load_async_checked(resource);
			pending.add(Std.string(request), font);
			pendingCount++;
		}
		#end
	}

	function finishResources():Void {
		if (stopped || session.state == UiHostLifecycle.Stopping ||
			session.state == UiHostLifecycle.Stopped) return;
		#if !nativekit_bundle_web_fonts
		if (loaded != null)
			for (font in options.fonts) {
				var bytes = loaded.get(font.name);
				if (bytes == null) throw "Missing downloaded browser font " + font.name;
				fonts.addData(font.name, bytes, font.family);
			}
		#end
		var activeEvents:NativeKitEvents = cast events;
		var activeFonts:FontCollection = cast fonts;
		// The page's canvas is this host's window and surface, so applications written against the desktop
		// context (native dialogs, auxiliary renderers) receive the same handles here.
		var context = new DesktopUiHostContext(activeFonts, activeEvents, window, surface, function() session.stop(),
			function() frameRequested = true);
		hostContext = context;
		var activeRuntime = new UiHostRuntime(session, context, window, surface,
			options.width, options.height);
		runtime = activeRuntime;
		activeRuntime.start(create);
		if (cleanupPending || session.state == UiHostLifecycle.Failed) {
			stopHost();
			return;
		}
		activeRuntime.setScale(pixelScale);
		activeRuntime.resize(logicalWidth, logicalHeight, framebufferWidth, framebufferHeight);
		activeRuntime.setSurfaceReady(surfaceReady);
		frameRequested = true;
	}

	function handleEvent(value:NativeKitEventValue):Void {
		if (stopped || stopping) return;
		frameRequested = true;
		try {
			switch (value) {
			case Raw(kind, _, request, loadResult, _, _, data)
				if (kind == EventKind.ResourceDataComplete):
				handleFont(request, loadResult, data);
			case WindowClose(source) if (source.rawValue() == window.rawValue()):
				var activeContext = hostContext;
				if (activeContext == null) session.stop(); else activeContext.requestClose();
			case WindowResize(source, width, height) if (source.rawValue() == window.rawValue()):
				logicalWidth = width;
				logicalHeight = height;
				if (NativeKit.nk_surface_set_bounds(surface, 0, 0, width, height) != Result.Ok)
					throw "Browser surface resize failed";
				frameRequested = true;
			case WindowScaleChanged(source, scale) if (source.rawValue() == window.rawValue()):
				pixelScale = scale;
				if (runtime != null) runtime.setScale(scale);
				frameRequested = true;
			case SurfaceReady(source) if (source.rawValue() == surface.rawValue()):
				if (NativeKit.nk_surface_make_current(surface) != Result.Ok)
					throw "Browser surface activation failed";
				var size = NativeKit.nk_surface_get_framebuffer_size(surface);
				if (size.status != Result.Ok) throw "Browser framebuffer size query failed";
				var scale = NativeKit.nk_window_get_scale(window);
				if (scale.status != Result.Ok) throw "Browser scale query failed";
				framebufferWidth = size.out_width;
				framebufferHeight = size.out_height;
				pixelScale = scale.out_scale;
				surfaceReady = framebufferWidth > 0 && framebufferHeight > 0;
				frameRequested = surfaceReady;
				var activeRuntime = runtime;
				if (activeRuntime != null) {
					activeRuntime.setScale(scale.out_scale);
					activeRuntime.resize(activeRuntime.logicalWidth, activeRuntime.logicalHeight,
						size.out_width, size.out_height);
					activeRuntime.setSurfaceReady(surfaceReady);
				}
			case SurfaceResize(source, width, height, framebufferWidth, framebufferHeight)
				if (source.rawValue() == surface.rawValue()):
				logicalWidth = width;
				logicalHeight = height;
				this.framebufferWidth = framebufferWidth;
				this.framebufferHeight = framebufferHeight;
				if (runtime != null) runtime.resize(width, height, framebufferWidth, framebufferHeight);
				if (surfaceReady) frameRequested = true;
			case SurfaceLost(source) if (source.rawValue() == surface.rawValue()):
				surfaceReady = false;
				if (runtime != null) runtime.setSurfaceReady(false);
			case _:
			}
		} catch (error:Dynamic) {
			fail("browser-event", error);
		}
	}

	function handleFont(request:haxe.Int64, result:Result, data:Bytes):Void {
		if (stopped || pending == null) return;
		var key = Std.string(request);
		var font = pending.resolve(key);
		if (font == null) return;
		if (result != Result.Ok || data.length == 0) {
			fail("font-load", "Failed to load browser font " + font.uri);
			return;
		}
		loaded.set(font.name, data);
		pendingCount--;
		if (pendingCount == 0) {
			pending = null;
			try {
				finishResources();
			} catch (error:Dynamic) {
				fail("font-create", error);
			}
		}
	}

	@:allow(nativekit.ui.host.BrowserUiHostSession)
	function advance(timeMilliseconds:Float):Int {
		if (stopped) return session.state == UiHostLifecycle.Failed ? -1 : 0;
		try {
			eventDispatching = true;
			while (!stopping && events != null && events.poll()) {}
			eventDispatching = false;
			if (cleanupPending || stopping) {
				stopHost();
				return session.state == UiHostLifecycle.Failed ? -1 : 0;
			}
			var backgroundPoll:Null<Void->Void> = hostContext == null ? null : hostContext.onPoll;
			if (backgroundPoll != null) backgroundPoll();
			var activeRuntime = runtime;
			if (frameRequested && activeRuntime != null && activeRuntime.surfaceReady &&
				session.state == UiHostLifecycle.Running) {
				frameRequested = false;
				if (NativeKit.nk_surface_make_current(surface) != Result.Ok)
					throw "Browser surface activation failed";
				activeRuntime.render(timeMilliseconds / 1000.0);
				if (cleanupPending || session.state != UiHostLifecycle.Running) {
					stopHost();
					return session.state == UiHostLifecycle.Failed ? -1 : 0;
				}
				if (NativeKit.nk_surface_present(surface) != Result.Ok)
					throw "Browser surface presentation failed";
				// Preserve the existing continuously animated showcase contract. A later
				// idle policy can stop this implicit request without changing schedulers.
				frameRequested = true;
			}
			return 1;
		} catch (error:Dynamic) {
			eventDispatching = false;
			fail("browser-frame", error);
			return -1;
		}
	}

	function fail(stage:String, error:Dynamic):Void {
		if (runtime != null) runtime.fail(stage, error);
		else session.fail(stage, error);
		stopHost();
	}

	@:allow(nativekit.ui.host.BrowserUiHostSession)
	function stopHost():Void {
		if (stopped) return;
		stopping = true;
		if (pending != null) pending.cancel();
		pending = null;
		loaded = null;
		pendingCount = 0;
		if (eventDispatching) {
			cleanupPending = true;
			return;
		}
		var activeRuntime = runtime;
		if (activeRuntime != null) activeRuntime.dispose();
		if (activeRuntime != null && activeRuntime.isCallbackActive()) {
			cleanupPending = true;
			return;
		}
		cleanupPending = false;
		stopped = true;
		var ownedSubscription = eventSubscription;
		eventSubscription = null;
		if (ownedSubscription != null)
			try ownedSubscription.dispose() catch (error:Dynamic) session.cleanupFailed("event-subscription", error);
		runtime = null;
		hostContext = null;
		var ownedFonts = fonts;
		fonts = null;
		if (ownedFonts != null)
			try ownedFonts.dispose() catch (error:Dynamic) session.cleanupFailed("fonts-dispose", error);
		var ownedSurface = surface;
		surface = SurfaceHandle.invalid();
		if (ownedSurface.isValid())
			try NativeKit.nk_surface_destroy(ownedSurface) catch (error:Dynamic) session.cleanupFailed("surface-destroy", error);
		var ownedWindow = window;
		window = WindowHandle.invalid();
		if (ownedWindow.isValid())
			try NativeKit.nk_window_destroy(ownedWindow) catch (error:Dynamic) session.cleanupFailed("window-destroy", error);
		var wasInitialized = initialized;
		initialized = false;
		if (wasInitialized)
			try NativeKit.nk_shutdown() catch (error:Dynamic) session.cleanupFailed("nativekit-shutdown", error);
		var ownedEvents = events;
		events = null;
		if (ownedEvents != null)
			try ownedEvents.runtimeShutdown() catch (error:Dynamic) session.cleanupFailed("events-shutdown", error);
		if (session.state != UiHostLifecycle.Failed)
			session.transition(UiHostLifecycle.Stopped);
	}
}
