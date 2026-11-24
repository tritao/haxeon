import haxeon.gpu.SurfaceOptions;
import haxeon.platform.Surface;
import haxeon.platform.App;
import haxeon.platform.AppLoop;
import haxeon.platform.FrameTick;
import haxeon.platform.FrameRecorder;
import haxeon.platform.SurfaceFrame;
import haxeon.ui.FontCollection;
import haxeon.ui.Renderer;
import haxeon.ui.core.UiContext;
import haxeon.ui.host.UiSurfaceBinding;
import haxeon.platform.Runtime;
import haxeon.platform.WindowOptions;
import nativekit.ffi.NativeKitTypes;
import Circuit.CircuitEvent;
import Circuit.Position;

class Main implements App {
	static inline var stepSeconds = 1.0 / Circuit.ticksPerSecond;

	final game = new Circuit();
	final sounds:Sounds;
	var surface:Surface;
	var renderer:CircuitRenderer;
	var hud:CircuitHud;
	var hudContext:UiContext;
	var hudRenderer:Renderer;
	var hudFonts:FontCollection;
	var hudBinding:UiSurfaceBinding;
	final runtime:Runtime;

	var running = true;

	var previousPlayer:Position;
	var previousDrone:Position;
	var lastFrame = 0.0;
	var accumulator = 0.0;

	#if circuit_run_web
	static var app:Main;
	static var loop:AppLoop;

	public static function main():Void {
		var runtime = Runtime.start();
		var sounds = new Sounds();
		app = new Main(runtime, sounds);
		try {
			app.start();
			loop = runtime.startApp(app.surface, app);
		} catch (error:Dynamic) {
			shutdown();
			throw error;
		}
	}

	public static function poll():Int {
		if (app == null)
			return -1;
		try {
			if (!loop.tick()) {
				shutdown();
				return 2;
			}
		} catch (error:Dynamic) {
			Sys.println("Circuit Run frame failed: " + Std.string(error));
			shutdown();
			return -1;
		}
		return loop.firstFramePresented ? 1 : 0;
	}

	public static function shutdown():Void {
		if (app == null)
			return;
		if (loop != null && !loop.stop())
			return;
		var stopped = app;
		app = null;
		defer stopped.runtime.dispose();
		defer stopped.sounds.dispose();
		defer stopped.dispose();
		if (loop != null) {
			loop.dispose();
			loop = null;
		}
	}
	#else
	static function main():Void {
		scoped var runtime = Runtime.start();
		scoped var sounds = new Sounds();
		var app = new Main(runtime, sounds);
		defer app.dispose();
		app.start();
		var recorder = Sys.getEnv("CIRCUIT_RUN_TIMING") == "1" ? new FrameRecorder(
			function(timing) Sys.println('frame ${timing.frameId} callback=${timing.callbackSeconds} submitted=${timing.submittedSeconds}'),
			function(timing, seconds) Sys.println('frame ${timing.frameId} presented=${seconds}')) : null;
		runtime.run(app.surface, app, recorder);
	}
	#end

	function new(runtime:Runtime, sounds:Sounds) {
		this.runtime = runtime;
		this.sounds = sounds;
	}

	function start():Void {
		var options = new WindowOptions(CircuitRenderer.width, CircuitRenderer.surfaceHeight);
		options.title = "Circuit Run | Arrows to steer, R to restart, M to mute";
		options.flags = WindowFlags.Resizable;
		var window = runtime.createWindow(options);
		surface = window.createSurface(SurfaceOptions.forGpu(CircuitRenderer.width, CircuitRenderer.surfaceHeight));
		hudFonts = FontCollection.create();
		#if circuit_run_web
		hudFonts.add("/assets/IBMPlexSans-Regular.ttf");
		#else
		hudFonts.addSystemFallbacks();
		#end
		hudRenderer = Renderer.create();
		hudContext = new UiContext(null, hudFonts);
		hudBinding = UiSurfaceBinding.attach(hudContext, window, surface, runtime.events);
		hudBinding.setFrameWidth(CircuitRenderer.width);
		hud = new CircuitHud(game, sounds.soundEnabled, restart, toggleSound);
		window.onClose(function() running = false);
		window.onKey(handleKey);
		snapshotPositions();
	}

	public function afterFrame():Void
		sounds.flush();

	public function shouldQuit():Bool
		return !running;

	function dispose():Void {
		defer if (hudFonts != null) hudFonts.dispose();
		defer if (hudRenderer != null) hudRenderer.dispose();
		defer if (hudContext != null) hudContext.dispose();
		if (hudBinding != null)
			hudBinding.dispose();
	}

	public function ready():Void
		renderer = new CircuitRenderer(surface);

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
		lastFrame = 0.0;
		hudBinding.invalidateFrame();
	}

	function toggleSound():Void {
		sounds.toggleMute();
		hudBinding.invalidateFrame();
	}

	function onGameEvent(event:CircuitEvent):Void {
		sounds.enqueue(switch event {
			case NodeCollected: Pickup;
			case RoundFinished(Captured): Caught;
			case RoundFinished(Cleared): Clear;
		});
		hudBinding.invalidateFrame();
	}

	public function frame(tick:FrameTick, frame:SurfaceFrame):Void {
		var width = tick.width;
		var height = tick.height;
		var now = tick.timeSeconds;
		advanceSimulation(now);
		var progress = accumulator / stepSeconds;
		var player = lerp(previousPlayer, game.playerPosition(), progress);
		var drone = lerp(previousDrone, game.dronePosition(), progress);
		scoped var batch = renderer.record(game, player, drone, width, height);
		var gpuStep = batch.frameStep();
		defer gpuStep.dispose();
		var uiStep = hudBinding.frameStep(hud, hudRenderer, frame, tick);
		defer uiStep.dispose();
		frame.submit([gpuStep, uiStep]);
	}

	function advanceSimulation(now:Float):Void {
		if (lastFrame != 0.0) {
			var elapsed = now - lastFrame;
			// Bound catch-up after a stall or a hidden window.
			accumulator += Math.min(elapsed, 0.1);
		}
		lastFrame = now;

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
