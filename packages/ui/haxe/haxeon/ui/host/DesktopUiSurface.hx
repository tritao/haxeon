package haxeon.ui.host;

import haxeon.platform.DisposalRegistration;
import haxe.Exception;
import haxeon.platform.Surface;
import haxeon.gpu.SurfaceOptions;
import haxeon.platform.Window;
import haxeon.platform.event.EventPump;
import haxeon.ui.FontCollection;
import haxeon.ui.Renderer;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.View;
import nativekit.ffi.NativeKitTypes.SurfaceFrameMode;
import nativekit.ffi.NativeKitTypes.SurfaceFlags;

/** Mounts an on-demand UI view on a surface within a managed desktop window. */
class DesktopUiSurface implements Disposable {
	final surface:Surface;
	var registration:DisposalRegistration;
	var binding:UiSurfaceBinding;
	var renderer:Renderer;
	var fonts:FontCollection;
	var context:UiContext;
	var disposed = false;

	public static function mount(window:Window, events:EventPump, width:Int, height:Int, view:View,
			onError:Exception->Void):DesktopUiSurface {
		var mounted = new DesktopUiSurface(window, width, height);
		var ready = false;
		defer if (!ready) mounted.dispose();
		mounted.start(window, events, width, height, view, onError);
		ready = true;
		return mounted;
	}

	function new(window:Window, width:Int, height:Int) {
		surface = window.createSurface(SurfaceOptions.forGpu(width, height, SurfaceFlags.Stencil));
		registration = window.registerDependent(dispose);
	}

	function start(window:Window, events:EventPump, width:Int, height:Int, view:View, onError:Exception->Void):Void {
		fonts = FontCollection.create();
		fonts.addSystemFallbacks();
		renderer = Renderer.create();
		context = new UiContext(null, fonts);
		binding = UiSurfaceBinding.attach(context, window, surface, events, true);

		var frame = new UiSurfaceFrame(surface.nativeHandle(), width, height);
		var lastFrame = 0.0;
		surface.setFrameMode(SurfaceFrameMode.OnDemand);
		context.onAnimationFrameRequested = invalidate;
		surface.onFrame(function(framebufferWidth, framebufferHeight) {
			if (framebufferWidth <= 0 || framebufferHeight <= 0)
				return;
			try {
				var now = Sys.monotonicTime();
				var delta = lastFrame == 0.0 ? 0.0 : now - lastFrame;
				lastFrame = now;
				frame.configure(width, height, framebufferWidth, framebufferHeight, framebufferWidth / width, delta);
				context.submit(view, frame.layout);
				frame.render(context, renderer);
			} catch (error:Exception) {
				onError(error);
			}
		});
		invalidate();
	}

	public function invalidate():Void {
		if (!disposed)
			surface.requestFrame();
	}

	public function dispose():Void {
		if (disposed)
			return;
		disposed = true;
		defer registration.detach();
		defer surface.dispose();
		defer if (fonts != null) fonts.dispose();
		defer if (renderer != null) renderer.dispose();
		defer if (context != null) context.dispose();
		defer if (binding != null) binding.dispose();
		surface.clearFrameCallback();
	}
}
