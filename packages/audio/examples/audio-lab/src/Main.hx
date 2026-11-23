import audiolab.AudioLabEngine;
import audiolab.AudioLabView;
import haxeon.gpu.SurfaceOptions;
import haxeon.platform.Runtime;
import haxeon.platform.Surface;
import haxeon.platform.Window;
import haxeon.platform.event.PlatformEvent;
import haxeon.ui.FontCollection;
import haxeon.ui.Renderer;
import haxeon.ui.core.FrameworkErrorView;
import haxeon.ui.core.UiContext;
import haxeon.ui.host.UiSurfaceBinding;
import haxeon.ui.host.UiSurfaceFrame;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes;

/** Desktop entry point for NativeKit Audio Lab. */
class Main {
	static inline var INITIAL_WIDTH:Int = 1220;
	static inline var INITIAL_HEIGHT:Int = 820;

	public static function main():Int {
		try {
			scoped var runtime = Runtime.start();
			var windowOptions = new haxeon.platform.WindowOptions(INITIAL_WIDTH, INITIAL_HEIGHT);
			windowOptions.title = "NativeKit Audio Lab";
			windowOptions.flags = WindowFlags.Resizable;
			var window = runtime.createWindow(windowOptions);

			var surface = window.createSurface(SurfaceOptions.forGpu(INITIAL_WIDTH, INITIAL_HEIGHT,
				SurfaceFlags.Stencil));

			scoped var lab = new AudioLabEngine(true);
			scoped var fonts = FontCollection.create();
			fonts.addSystemFallbacks();
			scoped var renderer = Renderer.create();
			scoped var context = new UiContext(null, fonts);

			run(runtime, window, surface, renderer, context, lab);
			return 0;
		} catch (error:Dynamic) {
			Sys.println("nativekit-audio-lab: " + Std.string(error));
			return 20;
		}
	}

	static function run(runtime:Runtime, window:Window, surface:Surface, renderer:Renderer, context:UiContext,
			lab:AudioLabEngine):Void {
		var view = new AudioLabView(lab);
		var events = runtime.events;
		var windowHandle = window.nativeHandle();
		var nativeSurface = surface.nativeHandle();
		var running = true;
		var logicalWidth = INITIAL_WIDTH;
		var logicalHeight = INITIAL_HEIGHT;
		var previousFrameAt = Date.now().getTime();
		var frameCount = 0;
		var frame = new UiSurfaceFrame(nativeSurface, INITIAL_WIDTH, INITIAL_HEIGHT);
		var errorView:Null<FrameworkErrorView> = null;
		scoped var binding = UiSurfaceBinding.attach(context, window, surface, events);
		scoped var eventSubscription = events.listen(function(value) {
			switch (value) {
				case WindowClose(source) if (source.rawValue() == windowHandle.rawValue()):
					running = false;
				case WindowResize(source, width, height) if (source.rawValue() == windowHandle.rawValue()):
					if (width > 0 && height > 0)
						NativeKit.nk_surface_set_bounds_checked(nativeSurface, 0, 0, width, height);
				case SurfaceResize(source, width, height, _, _) if (surface.ownsEventSource(source)):
					logicalWidth = width;
					logicalHeight = height;
				case _:
			}
		});

		scoped var frameSubscription = surface.onFrame(function(framebufferWidth, framebufferHeight) {
			if (!running || framebufferWidth <= 0 || framebufferHeight <= 0)
				return;
			try {
				if (errorView != null) {
					frame.configure(logicalWidth, logicalHeight, framebufferWidth, framebufferHeight,
						framebufferWidth / logicalWidth, 0.0);
					context.submit(errorView, frame.layout);
					frame.render(context, renderer);
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
				frame.configure(logicalWidth, logicalHeight, framebufferWidth, framebufferHeight,
					framebufferWidth / logicalWidth, deltaSeconds);
				context.submit(view, frame.layout);
				frame.render(context, renderer);
				if (NativeKit.nk_surface_request_frame(nativeSurface) != Result.Ok)
					running = false;
			} catch (error:Dynamic) {
				var message = Std.string(error);
				var stage = context.getDiagnosticStage();
				Sys.println('nativekit-audio-lab: frame ${frameCount} failed at stage ${stage}: ' + message);
				errorView = new FrameworkErrorView(message, stage);
				try {
					frame.configure(logicalWidth, logicalHeight, framebufferWidth, framebufferHeight,
						framebufferWidth / logicalWidth, 0.0);
					context.submit(errorView, frame.layout);
					frame.render(context, renderer);
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
	}
}
