package haxeon.ui.host;

import haxeon.platform.EventLoop;
import haxeon.platform.Surface;
import haxeon.platform.SurfaceFrameSubscription;
import haxeon.platform.event.EventPump;
import haxeon.platform.event.EventSubscription;
import haxeon.platform.event.PlatformEvent;
import nativekit.ffi.NativeKitTypes.SurfaceOptions as NativeSurfaceOptions;
import nativekit.ffi.NativeKitTypes.WindowOptions as NativeWindowOptions;

import haxeon.ProfileFrame;
import haxeon.ProfileNativeTrace;
import haxeon.ProfileSpan;

import haxe.Json;
import haxe.io.Bytes;
import haxeon.ui.FontCollection;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitGpu;
import nativekit.ffi.NativeKitTypes;
import sys.io.File;

/** Owns the complete NativeKit desktop lifecycle for one UIKit application. */
class DesktopUiHost {
	public static function run(options:DesktopUiHostOptions,
			create:DesktopUiHostContext->UiApplication):Int {
		var host = open(options, create);
		EventLoop.run(host.tick);
		return host.close();
	}

	public static function open(options:DesktopUiHostOptions,
			create:DesktopUiHostContext->UiApplication):DesktopUiHostSession {
		if (options == null || create == null)
			throw "Desktop UI host requires options and an application factory";
		options.validate();
		var initialized = false;
		var window = WindowHandle.invalid();
		var surface = SurfaceHandle.invalid();
		var events:Null<EventPump> = null;
		var eventSubscription:Null<EventSubscription> = null;
		var recordSubscription:Null<EventSubscription> = null;
		var inputTraceSubscription:Null<EventSubscription> = null;
		var recordPath:Null<String> = null;
		var nativeSurface:Null<Surface> = null;
		var frameSubscription:Null<SurfaceFrameSubscription> = null;
		var fonts:Null<FontCollection> = null;
		var runtime:Null<UiHostRuntime> = null;
		var session:Null<UiHostSession> = null;
		var recorder = new DesktopFrameRecorder(options);
		var frameGc = FrameGcScheduler.fromEnvironment();
		// A profiler frame runs from one rendered frame to the next, or until the host goes idle.
		var profileFrameOpen = false;
		var script = options.inputScriptPath == null ? null : new ScriptedInput(options.inputScriptPath);
		var scriptedCount = 0;
		var scriptedAt = -1.0;
		var scriptedDeliveredAt = -1.0;
		var scriptedDispatch = 0.0;
		var result = 0;
		var step:Void->Bool = function() return false;
		var failureRecorded = false;
		var recordFailure = function(stage:String, error:Dynamic):Void {
			if (recordPath == null || failureRecorded) return;
			failureRecorded = true;
			try {
				var appState:Dynamic = null;
				try {
					if (runtime != null) appState = DesktopFrameRecorder.diagnosticState(runtime.app());
				} catch (_:Dynamic) {}
				File.appendContent(recordPath, Json.stringify({
					kind: "failure",
					at: Sys.time(),
					stage: stage,
					message: Std.string(error),
					stack: haxe.CallStack.toString(haxe.CallStack.exceptionStack()),
					appState: appState
				}) + "\n");
			} catch (_:Dynamic) {}
		};

		try {
			var init = new InitOptions();
			init.set_api_version(NativeKit.nk_api_version());
			init.set_event_queue_capacity(options.eventQueueCapacity);
			init.set_application_id(options.applicationId);
			init.set_application_name(options.title);
			if (NativeKit.nk_init(init) != Result.Ok)
				throw "NativeKit initialization failed: " + NativeKit.nk_last_error();
			initialized = true;
			// NativeKit's waits, frames and input then appear in profiler captures.
			ProfileNativeTrace.install("nativekit");

			var initialWidth = Std.int(Math.max(options.width, options.minimumWidth));
			var initialHeight = Std.int(Math.max(options.height, options.minimumHeight));
			var windowOptions = new NativeWindowOptions();
			windowOptions.set_width(initialWidth);
			windowOptions.set_height(initialHeight);
			windowOptions.set_title(options.title);
			// Assign window icons before Windows creates its taskbar button.
			var deferShowForIcon = options.icons != null && Sys.systemName() == "Windows";
			var customChrome = options.customTitlebar
				&& haxe.Int64.compare(haxe.Int64.and(NativeKit.nk_get_capabilities(),
				Capabilities.windowCustomDecorations()), haxe.Int64.ofInt(0)) != 0;
			windowOptions.set_flags(WindowFlags.Resizable | (customChrome ? WindowFlags.Borderless
				: WindowFlags.empty()) | (deferShowForIcon ? WindowFlags.Hidden : WindowFlags.empty()));
			windowOptions.set_owner(WindowHandle.invalid());
			windowOptions.set_kind(WindowKind.Normal);
			var createdWindow = NativeKit.nk_window_create(windowOptions);
			if (createdWindow.status != Result.Ok)
				throw "Window creation failed: " + NativeKit.nk_last_error();
			window = createdWindow.out_window.borrow();
			var applySizeLimits = function(zoom:Float):Void {
				if (options.minimumWidth == 0 && options.minimumHeight == 0) return;
				var limits = new WindowSizeLimits();
				limits.set_min_width(Math.ceil(options.minimumWidth * zoom));
				limits.set_min_height(Math.ceil(options.minimumHeight * zoom));
				if (NativeKit.nk_window_set_size_limits(window, limits) != Result.Ok)
					throw "Window size limits failed: " + NativeKit.nk_last_error();
				// Updating native hints alone need not resize an existing window.
				var size = NativeKit.nk_window_get_size(window);
				if (size.status != Result.Ok) throw "Window size query failed: " + NativeKit.nk_last_error();
				var width = Std.int(Math.max(size.out_width, Math.ceil(options.minimumWidth * zoom)));
				var height = Std.int(Math.max(size.out_height, Math.ceil(options.minimumHeight * zoom)));
				if (width != size.out_width || height != size.out_height) {
					var position = NativeKit.nk_window_get_position(window);
					if (position.status != Result.Ok) throw "Window position query failed: "
						+ NativeKit.nk_last_error();
					if (NativeKit.nk_window_set_bounds(window, position.out_x, position.out_y, width, height)
						!= Result.Ok)
						throw "Window minimum resize failed: " + NativeKit.nk_last_error();
				}
			};
			applySizeLimits(1.0);
			if (options.icons != null) {
				var icons = options.icons;
				var pixels = Bytes.alloc(icons.byteCount);
				var images:Array<IconImage> = [];
				var offset = 0;
				for (icon in icons.imageList()) {
					pixels.blit(offset, icon.pixels, 0, icon.pixels.length);
					var image = new IconImage();
					image.set_offset(offset);
					image.set_width(icon.width);
					image.set_height(icon.height);
					image.set_stride(icon.stride);
					images.push(image);
					offset += icon.pixels.length;
				}
				if (NativeKit.nk_window_set_icons(window, pixels, images) != Result.Ok)
					throw "Window icons failed: " + NativeKit.nk_last_error();
			}
			// The outer bounds in logical pixels, which a later run can pass back as the placement.
			var readPlacement = function():Null<WindowPlacement> {
				var position = NativeKit.nk_window_get_position(window);
				var size = NativeKit.nk_window_get_size(window);
				if (position.status != Result.Ok || size.status != Result.Ok) return null;
				// The size is the client area's; the bounds set on the next run are the outer frame's.
				var width = size.out_width, height = size.out_height;
				var frame = NativeKit.nk_window_get_frame_extents(window);
				if (frame.status == Result.Ok) {
					width += frame.out_extents.get_left() + frame.out_extents.get_right();
					height += frame.out_extents.get_top() + frame.out_extents.get_bottom();
				}
				return new WindowPlacement(position.out_x, position.out_y, width, height, false);
			};
			// Whether the bounds, set on this window as they are, would overlap a connected monitor. A monitor the
			// window was on may since have been disconnected. When the monitors cannot be listed, the answer is yes.
			var onSomeMonitor = function(bounds:WindowPlacement):Bool {
				var scale = NativeKit.nk_window_get_scale(window);
				var monitors = Bytes.alloc(16 * 4);
				var count = Bytes.alloc(4);
				count.setInt32(0, 16);
				if (scale.status != Result.Ok || NativeKit.nk_monitor_list(monitors, count) != Result.Ok) return true;
				for (index in 0...count.getInt32(0)) {
					var geometry = NativeKit.nk_monitor_get_geometry(new MonitorHandle(monitors.getInt32(index * 4)));
					if (geometry.status != Result.Ok) continue;
					var monitor = geometry.out_geometry;
					// Windows reports monitors at the system scale and a window's bounds at the window's own scale.
					var toWindow = Sys.systemName() == "Windows" ? monitor.get_scale_x() / scale.out_scale : 1.0;
					if (bounds.x < (monitor.get_x() + monitor.get_width()) * toWindow
						&& monitor.get_x() * toWindow < bounds.x + bounds.width
						&& bounds.y < (monitor.get_y() + monitor.get_height()) * toWindow
						&& monitor.get_y() * toWindow < bounds.y + bounds.height)
						return true;
				}
				return false;
			};
			// A saved placement is applied while the window is still hidden (Windows), so it opens there without a jump.
			// A placement that cannot be applied, or lies on no monitor, is ignored: the window keeps the place the
			// system gave it. The placement was saved at the scale of the monitor the window was on, while the bounds
			// are set at the scale of the monitor the system chose; moving there can change the scale, so the bounds
			// are set once more at the new one.
			var placement = options.placement;
			if (placement != null && placement.width > 0 && placement.height > 0 && onSomeMonitor(placement)) {
				var scale = NativeKit.nk_window_get_scale(window);
				NativeKit.nk_window_set_bounds(window, placement.x, placement.y, placement.width, placement.height);
				var moved = NativeKit.nk_window_get_scale(window);
				if (scale.status == Result.Ok && moved.status == Result.Ok && moved.out_scale != scale.out_scale)
					NativeKit.nk_window_set_bounds(window, placement.x, placement.y, placement.width, placement.height);
			}
			// The bounds a maximized window restores to are the last ones read while it was not maximized, first
			// the ones it opens with, so a window maximized from the start still has a placement to save.
			var restoredPlacement = readPlacement();
			if (deferShowForIcon && NativeKit.nk_window_show(window, true) != Result.Ok)
				throw "Window show failed: " + NativeKit.nk_last_error();
			if (placement != null && placement.maximized)
				NativeKit.nk_window_maximize(window);
			// Windows does not bring a new window forward by itself; without this a reopened window lands behind.
			if (options.activate)
				NativeKit.nk_window_activate(window);

			var graphicsApi:GraphicsApi = NativeKitGpu.nkgpu_default_graphics_api();
			var surfaceOptions = new NativeSurfaceOptions();
			var surfaceFlags = SurfaceFlags.Stencil;
			if (graphicsApi == GraphicsApi.Opengl) {
				surfaceFlags = SurfaceFlags.ForwardCompatible | SurfaceFlags.Stencil;
				surfaceOptions.set_major_version(3);
				surfaceOptions.set_minor_version(3);
			}
			surfaceOptions.set_flags(surfaceFlags);
			surfaceOptions.set_api(graphicsApi);
			surfaceOptions.set_width(initialWidth);
			surfaceOptions.set_height(initialHeight);
			var createdSurface = NativeKit.nk_surface_create(new Handle(window.rawValue()), surfaceOptions);
			if (createdSurface.status != Result.Ok)
				throw "Surface creation failed: " + NativeKit.nk_last_error();
			surface = createdSurface.out_surface.borrow();

			var pump = new EventPump();
			events = pump;
			if (options.recordPath != null) {
				var path:String = cast options.recordPath;
				var slash = path.lastIndexOf("/");
				if (slash > 0) DesktopFrameRecorder.createDirectories(path.substr(0, slash));
				recordPath = path;
				Sys.println("recording Materia events in " + path);
				File.saveContent(path, Json.stringify({
					kind: "start",
					at: Sys.time(),
					width: options.width,
					height: options.height,
					metadata: options.recordMetadata
				}) + "\n");
				recordSubscription = pump.listen(function(value) {
					File.appendContent(path,
						Json.stringify({kind: "event", at: Sys.time(), event: Std.string(value)}) + "\n");
				});
			}
			fonts = FontCollection.create();
			fonts.addDefaultFonts();
			var active = true;
			var surfaceAvailable = false;
			var framePending = false;
			var frameRequested = false;
			var repaintOnlyRequested = false;
			var nextCaretFrameAt = -1.0;
			var nextAnimationFrameAt = -1.0;
			inputTraceSubscription = recorder.attach(pump, window);
			var scheduleFrameWithReason = function(reason:String):Void {
				repaintOnlyRequested = (!frameRequested || repaintOnlyRequested) && reason == "text-caret";
				frameRequested = true;
				recorder.request(reason);
			};
			// GTK's paint phase needs the successor armed before control returns.
			// Its backend pump yields after delivery; other desktop pumps may drain
			// repeated callbacks, so keep their existing request timing.
			var requestSuccessorDuringPaint = Sys.systemName() == "Linux";
			var submitFrameRequest = function():Void {
				if (active && surfaceAvailable && frameRequested && !framePending) {
					if (NativeKit.nk_surface_request_frame(surface) != Result.Ok)
						throw "Surface frame request failed";
					framePending = true;
				}
			};
			var scheduleFrame = function():Void scheduleFrameWithReason("api");
			scheduleFrameWithReason("startup");
			session = new UiHostSession(function() active = false);
			var hostContext = new DesktopUiHostContext(fonts, pump, window, surface,
				function() session.stop(), scheduleFrame);
			if (customChrome) hostContext.windowControls = new WindowControls(window, hostContext);
			hostContext.windowActive = function():Bool {
				var state = NativeKit.nk_window_get_state(window);
				return state.status == Result.Ok && state.out_state.get_flags().contains(WindowStateFlags.Active);
			};
			hostContext.windowPlacement = function():Null<WindowPlacement> {
				var state = NativeKit.nk_window_get_state(window);
				if (state.status != Result.Ok) return null;
				var flags = state.out_state.get_flags();
				if (flags.contains(WindowStateFlags.Minimized)
					|| flags.contains(WindowStateFlags.Fullscreen)) return null;
				var last = restoredPlacement;
				if (flags.contains(WindowStateFlags.Maximized))
					return last == null ? null : new WindowPlacement(last.x, last.y, last.width, last.height, true);
				var current = readPlacement();
				if (current != null) restoredPlacement = current;
				return current;
			};
			var liveRuntime = new UiHostRuntime(session, hostContext, window, surface,
				initialWidth, initialHeight, applySizeLimits);
			runtime = liveRuntime;
			liveRuntime.start(function(_) return create(hostContext));
			if (session.state == UiHostLifecycle.Failed) throw session.error;
			var borrowedSurface = Surface.borrowNativeHandle(surface);
			nativeSurface = borrowedSurface;

			// The Win32 sizing loop blocks this pump for the whole drag. Every intermediate size is
			// queued and replayed one per iteration afterwards, and a full queue drops the final one.
			// Applying the live size makes the first replayed event final and the rest no-ops.
			var windowsResize = Sys.systemName() == "Windows";
			var resizeSurface = function(width:Int, height:Int):Void {
				if (windowsResize) {
					var size = NativeKit.nk_window_get_size(window);
					if (size.status != Result.Ok) throw "Window size query failed: " + NativeKit.nk_last_error();
					if (size.out_width == liveRuntime.logicalWidth
						&& size.out_height == liveRuntime.logicalHeight) return;
					width = size.out_width;
					height = size.out_height;
				}
				if (NativeKit.nk_surface_set_bounds(surface, 0, 0, width, height) != Result.Ok)
					throw "Surface resize failed";
				liveRuntime.resize(width, height, liveRuntime.framebufferWidth, liveRuntime.framebufferHeight);
				scheduleFrameWithReason("window-resize");
			};
			eventSubscription = pump.listen(function(value) {
				var eventName = eventKind(value);
				recorder.event(value, eventName);
				switch (value) {
					case WindowClose(source) if (source.rawValue() == window.rawValue()):
						hostContext.requestClose();
						scheduleFrameWithReason("window-close");
					// The application's Quit (Cmd-Q, the Dock, a menu's Quit role) closes this window as its close button does.
					case Raw(kind, _, _, _, _, _, _) if (kind == EventKind.ApplicationQuitRequested):
						hostContext.requestClose();
						scheduleFrameWithReason("application-quit");
					case WindowResize(source, width, height) if (source.rawValue() == window.rawValue()):
						resizeSurface(width, height);
					case WindowFramebufferResize(source, _,
						_) if (windowsResize && source.rawValue() == window.rawValue()):
						resizeSurface(0, 0);
					case WindowScaleChanged(source, scale) if (source.rawValue() == window.rawValue()):
						liveRuntime.setScale(scale);
						scheduleFrameWithReason("window-scale");
					case WindowStateChanged(source, flags) if (source.rawValue() == window.rawValue()):
						if (hostContext.windowControls != null) hostContext.windowControls.observe(flags);
						scheduleFrameWithReason("window-state");
					case WindowMove(source, _, _) if (source.rawValue() == window.rawValue()):
					// Moving the top-level window does not change the surface contents.
					// On X11 this event is emitted for every position update while the
					// window is dragged; redrawing the complete Haxe UI here competes
					// with the compositor and makes the drag less responsive.
					case SurfaceReady(source) if (source.rawValue() == surface.rawValue()):
						surfaceAvailable = true;
						var size = NativeKit.nk_surface_get_framebuffer_size(surface);
						if (size.status != Result.Ok) throw "Framebuffer size query failed";
						var scale = NativeKit.nk_window_get_scale(window);
						if (scale.status != Result.Ok) throw "Window scale query failed";
						liveRuntime.setScale(scale.out_scale);
						liveRuntime.resize(liveRuntime.logicalWidth, liveRuntime.logicalHeight,
							size.out_width, size.out_height);
						liveRuntime.setSurfaceReady(size.out_width > 0 && size.out_height > 0);
						if (frameSubscription == null)
							frameSubscription = borrowedSurface.onFrame(function(width, height) {
								var callbackAt = recorder.callbackTime();
								try {
									framePending = false;
									if (!active || !surfaceAvailable || !frameRequested) return;
									var repaintOnly = repaintOnlyRequested;
									// Keep delivered text input even if caret/API requests coalesce.
									var scriptedFrameCount = scriptedCount;
									var scriptedFrameAt = scriptedAt;
									var scriptedFrameDeliveredAt = scriptedDeliveredAt;
									var scriptedFrameDispatch = scriptedDispatch;
									scriptedCount = 0;
									scriptedAt = -1.0;
									scriptedDeliveredAt = -1.0;
									scriptedDispatch = 0.0;
									frameRequested = false;
									liveRuntime.resize(liveRuntime.logicalWidth, liveRuntime.logicalHeight, width,
										height);
									// macOS reports SurfaceReady before its Metal layer has a size, so the ready
									// event's framebuffer query can be 0x0. The first frame carries the real size.
									liveRuntime.setSurfaceReady(width > 0 && height > 0);
									recorder.begin(borrowedSurface, callbackAt, scriptedFrameCount, scriptedFrameAt,
										scriptedFrameDeliveredAt, scriptedFrameDispatch);
									liveRuntime.measureFrameTimings = recorder.enabled;
									ProfileFrame.mark();
									profileFrameOpen = true;
									var rendered = false;
									{
										ProfileSpan.begin("ui.frame");
										defer ProfileSpan.end("ui.frame");
										frameGc.beginFrame();
										rendered = liveRuntime.render(Sys.time(), repaintOnly);
										recorder.submitted(rendered);
										{
											ProfileSpan.begin("ui.frame.gc");
											defer ProfileSpan.end("ui.frame.gc");
											frameGc.endFrame();
										}
									}
									recorder.endRender();
									if (!rendered) return;
									var frameRendered = options.onFrameRendered;
									if (frameRendered != null) frameRendered();
									var frameFinishedAt = recorder.finishedAt();
									var renderedApp = liveRuntime.app();
									nextCaretFrameAt = renderedApp != null
										? renderedApp.context().textInput.takeCaretFrameAt() : -1.0;
									var animationWait = renderedApp != null
										? renderedApp.context().animationWaitSeconds() : -1.0;
									nextAnimationFrameAt = animationWait >= 0.0 ? Sys.time() + animationWait : -1.0;
									if (recorder.ready() && script != null) script.start(Sys.time());
									recorder.finishFrame(liveRuntime, repaintOnly, frameFinishedAt);
									if (session.state == UiHostLifecycle.Failed) active = false;
									if (recorder.reachedFrameLimit()) {
										if (recorder.enabled) recorder.write(window, liveRuntime);
										session.stop();
									}
									var continueFrames = options.continuousFrames;
									var needsAnimationFrame = liveRuntime.app().context().needsAnimationFrame;
									var wantsContinuousFrames = !needsAnimationFrame && continueFrames != null
										&& continueFrames();
									if (active && session.state == UiHostLifecycle.Running
										&& (recorder.needsFrames()
										|| needsAnimationFrame || wantsContinuousFrames)) {
										if (recorder.needsFrames())
											scheduleFrameWithReason("capture");
										else if (needsAnimationFrame)
											scheduleFrameWithReason("animation");
										else
											scheduleFrameWithReason("continuous");
									}
									// Waiting until the next host tick can miss GTK's frame-clock deadline.
									if (requestSuccessorDuringPaint) submitFrameRequest();
								} catch (error:Dynamic) {
									frameGc.endFrame();
									recordFailure("frame-callback", error);
									liveRuntime.fail("frame-callback", error);
									active = false;
								}
							});
						scheduleFrameWithReason("surface-ready");
					case SurfaceResize(source, width, height, framebufferWidth, framebufferHeight)
						if (source.rawValue() == surface.rawValue()):
						liveRuntime.resize(width, height, framebufferWidth, framebufferHeight);
						scheduleFrameWithReason("surface-resize");
					case SurfaceLost(source) if (source.rawValue() == surface.rawValue()):
						surfaceAvailable = false;
						framePending = false;
						nextAnimationFrameAt = -1.0;
						liveRuntime.setSurfaceReady(false);
					case _ if (isBackgroundIo(value)):
					case _:
						scheduleFrameWithReason("event:" + eventName);
				}
			});

			var checkpoint = function(label:String):Void {
				var activeScript = script;
				if (activeScript == null) return;
				if (recordPath != null) File.appendContent(recordPath, Json.stringify({
					kind: "checkpoint",
					label: label,
					at: Sys.time(),
					scheduledAt: activeScript.scheduledAt,
					delivered: activeScript.delivered,
					appState: DesktopFrameRecorder.diagnosticState(liveRuntime.app())
				}) + "\n");
			};
			var beforeScriptedInput = function(at:Float):Void {
				if (scriptedAt < 0) {
					scriptedAt = at;
					scriptedDeliveredAt = Sys.time();
				}
				scriptedCount++;
			};
			var afterScriptedInput = function(seconds:Float):Void {
				scriptedDispatch += seconds;
			};
			var drainScriptedInput = function():Bool {
				var delivered = false;
				while (script != null && script.tick(Sys.time(), pump, window, checkpoint,
					beforeScriptedInput, afterScriptedInput)) delivered = true;
				return delivered;
			};
			var eventLoop = new EventLoop(pump);
			var framesBeforePoll = 0;
			var hadEvent = false;
			var profilingPoll = false;
			var finishPoll = function(polled:Bool):Null<Float> {
				if (profilingPoll) {
					profilingPoll = false;
					ProfileSpan.end("ui.events");
				}
				if (polled) hadEvent = true;
				if (drainScriptedInput()) hadEvent = true;
				// Surface callbacks run directly in the backend pump, without a queued event.
				var hadFrame = liveRuntime.rendered != framesBeforePoll;
				recorder.endPoll(liveRuntime.rendered);
				var backgroundPoll:Null<Void->Void> = hostContext.onPoll;
				if (active && backgroundPoll != null) backgroundPoll();
				recorder.endBackground();
				if (session.state == UiHostLifecycle.Failed) throw session.error;
				if (active && recorder.elapsed() && (script == null || script.complete && scriptedCount == 0)) {
					if (recorder.enabled) recorder.write(window, liveRuntime);
					session.stop();
				}
				if (active && surfaceAvailable && nextCaretFrameAt >= 0.0 && Sys.time() >= nextCaretFrameAt) {
					nextCaretFrameAt = -1.0;
					scheduleFrameWithReason("text-caret");
				}
				if (active && surfaceAvailable && nextAnimationFrameAt >= 0.0
					&& Sys.time() >= nextAnimationFrameAt) {
					nextAnimationFrameAt = -1.0;
					scheduleFrameWithReason("animation");
				}
				submitFrameRequest();
				if (active && !hadEvent && !hadFrame && !frameRequested && !framePending) {
					frameGc.idle();
					if (profileFrameOpen) {
						ProfileFrame.idle();
						profileFrameOpen = false;
					}
				}
				if (!active || hadEvent || hadFrame) return null;
				recorder.beginWait(liveRuntime.rendered);
				var waitSeconds = 1.0 / options.targetFps;
				var scriptDeadline = script == null ? null : script.secondsUntilNext(Sys.time());
				if (scriptDeadline != null) waitSeconds = Math.min(waitSeconds, scriptDeadline);
				if (surfaceAvailable && nextAnimationFrameAt >= 0.0)
					waitSeconds = Math.min(waitSeconds, Math.max(0.0, nextAnimationFrameAt - Sys.time()));
				return waitSeconds;
			};
			step = function() {
				if (!active) return false;
				try {
					framesBeforePoll = liveRuntime.rendered;
					recorder.beginPoll(framesBeforePoll);
					// Native polling can render, so deliver already-due scripted input first.
					hadEvent = drainScriptedInput();
					ProfileSpan.begin("ui.events");
					profilingPoll = true;
					defer if (profilingPoll) {
						profilingPoll = false;
						ProfileSpan.end("ui.events");
					}
					var waited = eventLoop.step(finishPoll);
					if (waited) recorder.endWait(liveRuntime.rendered);
					if (session.state == UiHostLifecycle.Failed) throw session.error;
				} catch (error:Dynamic) {
					recordFailure("desktop-host", error);
					session.fail("desktop-host", error);
					Sys.println(options.title + ": " + Std.string(error));
					if (session.error != null && session.error.stack.length > 0)
						Sys.println(session.error.stack);
					active = false;
					result = 1;
				}
				return active;
			};
		} catch (error:Dynamic) {
			recordFailure("desktop-host", error);
			if (session != null && session.state != UiHostLifecycle.Failed)
				session.fail("desktop-host", error);
			var detail = Std.string(error);
			if (Std.isOfType(error, UiHostError)) {
				var hostError:UiHostError = cast error;
				detail = hostError.toString();
				var message = Reflect.field(hostError.cause, "message");
				if (message != null) detail = hostError.stage + ": " + Std.string(message);
			}
			Sys.println(options.title + ": " + detail);
			var stack = session != null && session.error != null && session.error.stack.length > 0
				? session.error.stack : haxe.CallStack.toString(haxe.CallStack.exceptionStack());
			if (stack.length > 0) Sys.println(stack);
			result = 1;
		}

		var finish = function() {
			recorder.stopCensus();
			var ownedRecordSubscription = recordSubscription;
			recordSubscription = null;
			if (ownedRecordSubscription != null)
				try ownedRecordSubscription.dispose() catch (_:Dynamic) {}
			var ownedRecordPath = recordPath;
			recordPath = null;
			if (ownedRecordPath != null)
				try File.appendContent(ownedRecordPath,
					Json.stringify({kind: "stop", at: Sys.time(), exitCode: result}) + "\n") catch (_:Dynamic) {}
			var ownedFrameSubscription = frameSubscription;
			frameSubscription = null;
			if (ownedFrameSubscription != null)
				try ownedFrameSubscription.dispose() catch (error:Dynamic) if (session != null)
					session.cleanupFailed("frame-subscription", error);
			var ownedInputTraceSubscription = inputTraceSubscription;
			inputTraceSubscription = null;
			if (ownedInputTraceSubscription != null)
				try ownedInputTraceSubscription.dispose() catch (error:Dynamic) if (session != null)
					session.cleanupFailed("input-trace-subscription", error);
			var ownedEventSubscription = eventSubscription;
			eventSubscription = null;
			if (ownedEventSubscription != null)
				try ownedEventSubscription.dispose() catch (error:Dynamic) if (session != null)
					session.cleanupFailed("event-subscription", error);
			var ownedRuntime = runtime;
			runtime = null;
			if (ownedRuntime != null) ownedRuntime.dispose();
			var ownedFonts = fonts;
			fonts = null;
			if (ownedFonts != null)
				try ownedFonts.dispose() catch (error:Dynamic) if (session != null)
					session.cleanupFailed("fonts-dispose", error);
			var ownedNativeSurface = nativeSurface;
			nativeSurface = null;
			if (ownedNativeSurface != null)
				try ownedNativeSurface.releaseBorrowed() catch (error:Dynamic) if (session != null)
					session.cleanupFailed("frame-surface-release", error);
			var ownedSurface = surface;
			surface = SurfaceHandle.invalid();
			if (ownedSurface.isValid())
				try NativeKit.nk_surface_destroy(ownedSurface) catch (error:Dynamic) if (session != null)
					session.cleanupFailed("surface-destroy", error);
			var ownedWindow = window;
			window = WindowHandle.invalid();
			if (ownedWindow.isValid())
				try NativeKit.nk_window_destroy(ownedWindow) catch (error:Dynamic) if (session != null)
					session.cleanupFailed("window-destroy", error);
			var wasInitialized = initialized;
			initialized = false;
			if (wasInitialized)
				try NativeKit.nk_shutdown() catch (error:Dynamic) if (session != null)
					session.cleanupFailed("nativekit-shutdown", error);
			var ownedEvents = events;
			events = null;
			if (ownedEvents != null)
				try ownedEvents.runtimeShutdown() catch (error:Dynamic) if (session != null)
					session.cleanupFailed("events-shutdown", error);
			if (session != null && session.state != UiHostLifecycle.Failed
				&& session.state != UiHostLifecycle.Stopped) {
				if (session.state != UiHostLifecycle.Stopping) session.transition(UiHostLifecycle.Stopping);
				session.transition(UiHostLifecycle.Stopped);
			}
			return result;
		};
		return new DesktopUiHostSession(step, finish);
	}

	static function eventKind(value:PlatformEvent):String {
		return switch (value) {
			case WindowClose(_): "WindowClose";
			case WindowResize(_, _, _): "WindowResize";
			case WindowMove(_, _, _): "WindowMove";
			case WindowFramebufferResize(_, _, _): "WindowFramebufferResize";
			case WindowScaleChanged(_, _): "WindowScaleChanged";
			case WindowStateChanged(_, _): "WindowStateChanged";
			case Key(_, _, _, _, _): "Key";
			case TextInput(_, _): "TextInput";
			case TextEdit(_, _): "TextEdit";
			case PointerMove(_, _, _): "PointerMove";
			case PointerButton(_, _, _, _, _, _): "PointerButton";
			case PointerScroll(_, _, _): "PointerScroll";
			case PointerEnter(_, _): "PointerEnter";
			case Touch(_, _, _, _, _, _, _, _, _, _): "Touch";
			case SurfaceReady(_): "SurfaceReady";
			case SurfaceResize(_, _, _, _, _): "SurfaceResize";
			case SurfaceLost(_): "SurfaceLost";
			case None: "None";
			case Raw(_, _, _, _, _, _, _): "Raw";
			case TaskProgress(_, _) | TaskComplete(_, _, _) | TaskFailed(_, _, _) | TaskCancelled(_, _, _): "Task";
			case HttpHeaders(_, _, _, _) | HttpDataAvailable(_, _) | HttpProgressEvent(_, _, _, _, _,
				_) | HttpComplete(_, _, _, _): "Http";
			case _: "other";
		};
	}

	/** Background I/O (transports, terminals, tasks, HTTP) is for the code that started it, not the window: a redraw
		for each chunk of a busy connection would draw continuously while nothing on screen changes. That code requests
		a frame when its state changes. Other raw events (menus, file watches, application lifecycle) still redraw. */
	static function isBackgroundIo(value:PlatformEvent):Bool {
		return switch (value) {
			case Raw(kind, _, _, _, _, _, _):
				kind == EventKind.TransportConnected || kind == EventKind.TransportAccepted
					|| kind == EventKind.TransportData || kind == EventKind.TransportWritable
					|| kind == EventKind.TransportClosed || kind == EventKind.TransportFailed
					|| kind == EventKind.PtyReadable || kind == EventKind.PtyExited;
			case TaskProgress(_, _) | TaskComplete(_, _, _) | TaskFailed(_, _, _) | TaskCancelled(_, _, _)
				| HttpHeaders(_, _, _, _) | HttpDataAvailable(_, _) | HttpProgressEvent(_, _, _, _, _, _)
				| HttpComplete(_, _, _, _): true;
			case _: false;
		};
	}

}
