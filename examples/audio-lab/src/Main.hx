import haxeon.ui.FontCollection;
import haxeon.ui.FrameInfo;
import haxeon.ui.LayoutFrame;
import haxeon.ui.Renderer;
import haxeon.ui.Surface;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes;
import haxeon.platform.NativeKitEvents;
import haxeon.platform.NativeKitEvents.NativeKitEventSubscription;
import haxeon.platform.NativeKitEventValue;
import haxeon.platform.NativeKitRuntime;
import haxeon.platform.NativeKitSurface;
import haxeon.platform.NativeKitSurface.NativeKitSurfaceFrameSubscription;
import haxeon.platform.NativeKitWindow;
import nativekit.ffi.NativeKitGpu;
import audiolab.AudioLabEngine;
import audiolab.AudioLabView;
import haxeon.ui.core.NativeInputAdapter;
import haxeon.ui.core.FrameworkErrorView;
import haxeon.ui.core.UiContext;

/** Desktop entry point for NativeKit Audio Lab. */
class Main {
	static inline var INITIAL_WIDTH:Int = 1220;
	static inline var INITIAL_HEIGHT:Int = 820;

	public static function main():Int {
		var runtime:Null<NativeKitRuntime> = null;
		var window:Null<NativeKitWindow> = null;
		var surface:Null<NativeKitSurface> = null;
		var fonts:Null<FontCollection> = null;
		var renderer:Null<Renderer> = null;
		var context:Null<UiContext> = null;
		var input:Null<NativeInputAdapter> = null;
		var frameSubscription:Null<NativeKitSurfaceFrameSubscription> = null;
		var eventSubscription:Null<NativeKitEventSubscription> = null;
		var lab:Null<AudioLabEngine> = null;
		try {
			var init = new InitOptions();
			init.set_api_version(NativeKit.nk_api_version());
			runtime = NativeKitRuntime.start(init);

			var windowOptions = new WindowOptions();
			windowOptions.set_width(INITIAL_WIDTH);
			windowOptions.set_height(INITIAL_HEIGHT);
			windowOptions.set_title("NativeKit Audio Lab");
			windowOptions.set_flags(WindowFlags.Resizable);
			windowOptions.set_owner(WindowHandle.invalid());
			windowOptions.set_kind(WindowKind.Normal);
			window = runtime.createWindow(windowOptions);

			var graphicsApi:GraphicsApi = NativeKitGpu.nkgpu_default_graphics_api();
			var surfaceOptions = new SurfaceOptions();
			var surfaceFlags = SurfaceFlags.Stencil;
			if (graphicsApi == GraphicsApi.Opengl) {
				surfaceFlags = SurfaceFlags.ForwardCompatible | SurfaceFlags.Stencil;
				surfaceOptions.set_major_version(3);
				surfaceOptions.set_minor_version(3);
			}
			surfaceOptions.set_flags(surfaceFlags);
			surfaceOptions.set_api(graphicsApi);
			surfaceOptions.set_width(INITIAL_WIDTH);
			surfaceOptions.set_height(INITIAL_HEIGHT);
			surface = window.createSurface(surfaceOptions);

			fonts = FontCollection.create();
			fonts.addSystemFallbacks();
			renderer = Renderer.create();
			context = new UiContext(null, fonts);
			context.attachPlatformSurface(surface);
			context.attachPlatformWindow(window.nativeHandle());

			lab = new AudioLabEngine(true);
			var view = new AudioLabView(lab);
			var events = runtime.events;
			var windowHandle = window.nativeHandle();
			var nativeSurface = surface.nativeHandle();
			var running = true;
			var logicalWidth = INITIAL_WIDTH;
			var logicalHeight = INITIAL_HEIGHT;
			var previousFrameAt = Date.now().getTime();
			var frameCount = 0;
			var layoutFrame = new LayoutFrame(logicalWidth, logicalHeight);
			var frameInfo = new FrameInfo(logicalWidth, logicalHeight, INITIAL_WIDTH, INITIAL_HEIGHT, 1.0);
			var errorView:Null<FrameworkErrorView> = null;
			input = new NativeInputAdapter(context, new Handle(windowHandle.rawValue()));
			input.attach(events);
			eventSubscription = events.listen(function(value) {
				switch (value) {
					case WindowClose(source) if (source.rawValue() == windowHandle.rawValue()):
						running = false;
					case SurfaceResize(source, width, height, _, _) if (source.rawValue() == nativeSurface.rawValue()):
						logicalWidth = width;
						logicalHeight = height;
					case _:
				}
			});

			frameSubscription = surface.onFrame(function(framebufferWidth, framebufferHeight) {
				if (!running || framebufferWidth <= 0 || framebufferHeight <= 0)
					return;
				try {
					if (errorView != null) {
						layoutFrame.setViewport(logicalWidth, logicalHeight);
						frameInfo.set(logicalWidth, logicalHeight, framebufferWidth, framebufferHeight, 1.0);
						context.submit(errorView, layoutFrame);
						context.render(renderer, Surface.fromNativeHandle(nativeSurface), frameInfo);
						if (NativeKit.nk_surface_request_frame(nativeSurface) != Result.Ok)
							running = false;
						return;
					}
					frameCount += 1;
					if (frameCount == 1)
						Sys.println('nativekit-audio-lab: first frame ${framebufferWidth}x${framebufferHeight}');
					var now = Date.now().getTime();
					var deltaSeconds = (now - previousFrameAt) / 1000.0;
					previousFrameAt = now;
					lab.advance(deltaSeconds);
					layoutFrame.setViewport(logicalWidth, logicalHeight);
					layoutFrame.deltaSeconds = deltaSeconds;
					frameInfo.set(logicalWidth, logicalHeight, framebufferWidth, framebufferHeight, 1.0);
					context.submit(view, layoutFrame);
					context.render(renderer, Surface.fromNativeHandle(nativeSurface), frameInfo);
					if (NativeKit.nk_surface_request_frame(nativeSurface) != Result.Ok)
						running = false;
				} catch (error:Dynamic) {
					var message = Std.string(error);
					var stage = context.getDiagnosticStage();
					Sys.println('nativekit-audio-lab: frame ${frameCount} failed at stage ${stage}: ' + message);
					errorView = new FrameworkErrorView(message, stage);
					try {
						layoutFrame.setViewport(logicalWidth, logicalHeight);
						frameInfo.set(logicalWidth, logicalHeight, framebufferWidth, framebufferHeight, 1.0);
						context.submit(errorView, layoutFrame);
						context.render(renderer, Surface.fromNativeHandle(nativeSurface), frameInfo);
						if (NativeKit.nk_surface_request_frame(nativeSurface) != Result.Ok)
							running = false;
					} catch (fallbackError:Dynamic) {
						Sys.println('nativekit-audio-lab: error view failed: ' + Std.string(fallbackError));
						running = false;
					}
				}
			});
			if (NativeKit.nk_surface_request_frame(nativeSurface) != Result.Ok)
				throw "initial surface frame request failed";

			while (running) {
				if (!events.poll())
					events.wait(1.0 / 60.0);
			}
			disposeAll(input, frameSubscription, eventSubscription, context, renderer, fonts, lab, runtime);
			return 0;
		} catch (error:Dynamic) {
			Sys.println("nativekit-audio-lab: " + Std.string(error));
			disposeAll(input, frameSubscription, eventSubscription, context, renderer, fonts, lab, runtime);
			return 20;
		}
	}

	static function disposeAll(input:Null<NativeInputAdapter>, frameSubscription:Null<NativeKitSurfaceFrameSubscription>,
		eventSubscription:Null<NativeKitEventSubscription>, context:Null<UiContext>, renderer:Null<Renderer>,
		fonts:Null<FontCollection>, lab:Null<AudioLabEngine>, runtime:Null<NativeKitRuntime>):Void {
		if (input != null)
			input.detach();
		if (frameSubscription != null)
			frameSubscription.dispose();
		if (eventSubscription != null)
			eventSubscription.dispose();
		if (context != null)
			context.dispose();
		if (renderer != null)
			renderer.dispose();
		if (fonts != null)
			fonts.dispose();
		if (lab != null)
			lab.dispose();
		if (runtime != null)
			runtime.dispose();
	}
}
