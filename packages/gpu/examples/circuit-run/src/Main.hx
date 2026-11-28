import Circuit.CircuitEvent;
import Circuit.Position;
import haxeon.gpu.SurfaceOptions;
import haxeon.platform.App;
import haxeon.platform.FrameRecorder;
import haxeon.platform.FrameTick;
import haxeon.platform.Runtime;
import haxeon.platform.Surface;
import haxeon.platform.SurfaceFrame;
import haxeon.platform.WindowOptions;
import haxeon.ui.host.UiOverlay;
import nativekit.ffi.NativeKitTypes;

class Main implements App {
	static inline var stepSeconds = 1.0 / Circuit.ticksPerSecond;

	final game = new Circuit();
	final sounds = new Sounds();
	var surface:Surface;
	var renderer:CircuitRenderer;
	var hud:UiOverlay;
	var hudView:CircuitHud;

	var running = true;

	var previousPlayer:Position;
	var previousDrone:Position;
	var accumulator = 0.0;

	public static function main():Void
		Runtime.launch(runtime -> new Main(runtime));

	function new(runtime:Runtime) {
		var initialized = false;
		defer if (!initialized) dispose();
		var options = new WindowOptions(CircuitRenderer.width, CircuitRenderer.surfaceHeight);
		options.title = "Circuit Run | Arrows to steer, R to restart, M to mute";
		options.flags = WindowFlags.Resizable;
		var window = runtime.createWindow(options);
		surface = window.createSurface(SurfaceOptions.forGpu(CircuitRenderer.width, CircuitRenderer.surfaceHeight));
		hud = UiOverlay.attach(window, surface, runtime.events, CircuitRenderer.width);
		hudView = new CircuitHud(game, sounds.soundEnabled, restart, toggleSound);

		window.onClose(() -> running = false);
		window.onKey(handleKey);
		snapshotPositions();
		var recorder = Sys.getEnv("CIRCUIT_RUN_TIMING") == "1"
			? new FrameRecorder(timing -> Sys.println('frame ${timing.frameId} callback=${timing.callbackSeconds} submitted=${timing.submittedSeconds}'),
			(timing, seconds) -> Sys.println('frame ${timing.frameId} presented=${seconds}')) : null;
		runtime.drive(surface, recorder);
		initialized = true;
	}

	public function afterFrame():Void
		sounds.flush();

	public function shouldQuit():Bool
		return !running;

	public function dispose():Void {
		defer sounds.dispose();
		if (hud != null) hud.dispose();
	}

	public function ready():Void
		switch CircuitRenderer.create(surface) {
			case Ok(created):
				renderer = created;
			case Err(error):
				Sys.println('Circuit Run cannot draw: ${error.describe()}');
				running = false;
		}

	function handleKey(key:Key, scancode:Int, action:InputAction, modifiers:Modifiers):Bool {
		if (action != InputAction.Press)
			return false;
		switch key {
			case Key.Right: game.steer(East);
			case Key.Down: game.steer(South);
			case Key.Left: game.steer(West);
			case Key.Up: game.steer(North);
			case Key.R: restart();
			case Key.M: toggleSound();
			case Key.Escape: running = false;
			case _: return false;
		}
		return true;
	}

	function restart():Void {
		game.reset();
		sounds.clear();
		snapshotPositions();
		accumulator = 0.0;
		hud.invalidate();
	}

	function toggleSound():Void {
		sounds.toggleMute();
		hud.invalidate();
	}

	function onGameEvent(event:CircuitEvent):Void {
		sounds.enqueue(switch event {
			case NodeCollected: Pickup;
			case RoundFinished(Captured): Caught;
			case RoundFinished(Cleared): Clear;
		});
		hud.invalidate();
	}

	public function frame(tick:FrameTick, frame:SurfaceFrame):Void {
		var width = tick.width;
		var height = tick.height;
		advanceSimulation(tick.deltaSeconds);
		var progress = accumulator / stepSeconds;
		var player = lerp(previousPlayer, game.playerPosition(), progress);
		var drone = lerp(previousDrone, game.dronePosition(), progress);
		scoped var batch = renderer.record(game, player, drone, width, height);
		var gpuStep = batch.frameStep();
		defer gpuStep.dispose();
		var uiStep = hud.frameStep(hudView, frame, tick);
		defer uiStep.dispose();
		frame.submit([gpuStep, uiStep]);
	}

	function advanceSimulation(deltaSeconds:Float):Void {
		accumulator += deltaSeconds;

		while (accumulator >= stepSeconds) {
			snapshotPositions();
			game.step(onGameEvent);
			accumulator -= stepSeconds;
		}
	}

	function snapshotPositions():Void {
		previousPlayer = game.playerPosition();
		previousDrone = game.dronePosition();
	}

	static function lerp(from:Position, to:Position, progress:Float):Position
		return {x: from.x + (to.x - from.x) * progress, y: from.y + (to.y - from.y) * progress};
}
