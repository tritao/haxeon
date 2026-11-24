import haxeon.gpu.SurfaceOptions;
import haxeon.platform.App;
import haxeon.platform.FrameTick;
import haxeon.platform.Runtime;
import haxeon.platform.Surface;
import haxeon.platform.SurfaceFrame;
import haxeon.platform.WindowOptions;
import haxeon.ui.host.UiOverlay;
import nativekit.ffi.NativeKitTypes;

class Main implements App {
	final surface:Surface;
	final overlay:UiOverlay;
	var scene:Null<Scene> = null;
	var open = true;

	public static function main():Void
		Runtime.launch(runtime -> new Main(runtime));

	function new(runtime:Runtime) {
		var options = new WindowOptions(960, 600);
		options.title = "Viewport";
		options.flags = WindowFlags.Resizable;
		var window = runtime.createWindow(options);
		window.onClose(() -> open = false);
		surface = window.createSurface(SurfaceOptions.forGpu(960, 600));
		overlay = UiOverlay.attach(window, surface, runtime.events);
		runtime.drive(surface);
	}

	public function ready():Void
		scene = new Scene(surface);

	public function frame(tick:FrameTick, frame:SurfaceFrame):Void {
		var scene = this.scene;
		if (scene != null) scene.draw(tick, frame, overlay);
	}

	public function afterFrame():Void {}

	public function shouldQuit():Bool
		return !open;

	public function dispose():Void {
		overlay.dispose();
		var scene = this.scene;
		if (scene != null) scene.dispose();
	}
}
