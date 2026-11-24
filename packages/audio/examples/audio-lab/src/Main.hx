import audiolab.AudioLabEngine;
import audiolab.AudioLabView;
import haxeon.gpu.SurfaceOptions;
import haxeon.platform.App;
import haxeon.platform.FrameTick;
import haxeon.platform.Runtime;
import haxeon.platform.SurfaceFrame;
import haxeon.platform.WindowOptions;
import haxeon.ui.core.FrameworkErrorView;
import haxeon.ui.host.UiOverlay;
import nativekit.ffi.NativeKitTypes.WindowFlags;

/** Audio Lab uses one frame for its controls and diagnostics. */
class Main implements App {
	static inline var width = 1220;
	static inline var height = 820;

	final lab = new AudioLabEngine(true);
	final view:AudioLabView;
	final overlay:UiOverlay;
	var running = true;
	var frames = 0;
	var lastDelta = 0.0;
	var errorView:Null<FrameworkErrorView>;

	public static function main():Void
		Runtime.launch(runtime -> new Main(runtime));

	function new(runtime:Runtime) {
		var initialized = false;
		defer if (!initialized) dispose();
		view = new AudioLabView(lab);
		var options = new WindowOptions(width, height);
		options.title = "NativeKit Audio Lab";
		options.flags = WindowFlags.Resizable;
		var window = runtime.createWindow(options);
		var surface = window.createSurface(SurfaceOptions.forGpu(width, height));
		overlay = UiOverlay.attach(window, surface, runtime.events);
		window.onClose(function() running = false);
		runtime.drive(surface);
		initialized = true;
	}

	public function ready():Void {}

	public function frame(tick:FrameTick, acquired:SurfaceFrame):Void {
		lastDelta = tick.deltaSeconds;
		frames++;
		if (frames == 1)
			Sys.println('nativekit-audio-lab: first frame ${tick.width}x${tick.height}');
		try {
			var step = overlay.frameStep(errorView == null ? view : errorView, acquired, tick);
			defer step.dispose();
			acquired.submit([step]);
		} catch (error:haxe.Exception) {
			if (errorView != null) throw error;
			Sys.println('nativekit-audio-lab: frame ${frames} failed: ' + error.message);
			errorView = new FrameworkErrorView(error.message, 0);
			overlay.invalidate();
		}
	}

	public function afterFrame():Void {
		if (errorView == null) {
			lab.advance(lastDelta);
			overlay.invalidate();
		}
	}

	public function shouldQuit():Bool
		return !running;

	public function dispose():Void {
		defer lab.dispose();
		if (overlay != null) overlay.dispose();
	}
}
