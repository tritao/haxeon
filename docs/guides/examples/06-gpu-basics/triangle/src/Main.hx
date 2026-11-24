import haxeon.gpu.SurfaceOptions;
import haxeon.platform.App;
import haxeon.platform.FrameTick;
import haxeon.platform.Runtime;
import haxeon.platform.Surface;
import haxeon.platform.SurfaceFrame;
import haxeon.platform.WindowOptions;

class Main implements App {
	final surface:Surface;
	var scene:Null<Scene> = null;
	var open = true;

	public static function main():Void
		Runtime.launch(runtime -> new Main(runtime));

	function new(runtime:Runtime) {
		var window = runtime.createWindow(new WindowOptions(640, 480));
		window.onClose(() -> open = false);
		surface = window.createSurface(SurfaceOptions.forGpu(640, 480));
		runtime.drive(surface);
	}

	public function ready():Void
		scene = new Scene(surface);

	public function frame(tick:FrameTick, frame:SurfaceFrame):Void {
		var scene = this.scene;
		if (scene != null) scene.draw(tick, frame);
	}

	public function afterFrame():Void {}

	public function shouldQuit():Bool
		return !open;

	public function dispose():Void {
		var scene = this.scene;
		if (scene != null) scene.dispose();
	}
}
