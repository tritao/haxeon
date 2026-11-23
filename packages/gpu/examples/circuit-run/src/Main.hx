import haxeon.gpu.Batch;
import haxeon.gpu.SurfaceOptions;
import haxeon.platform.Surface;
import haxeon.platform.SurfaceFrameSubscription;
import haxeon.ui.FontCollection;
import haxeon.ui.FrameInfo;
import haxeon.ui.LayoutFrame;
import haxeon.ui.Renderer;
import haxeon.ui.core.UiContext;
import haxeon.ui.host.UiSurfaceBinding;
import haxeon.platform.Runtime;
import haxeon.platform.WindowOptions;
import nativekit.ffi.NativeKitTypes;
import Circuit.CircuitEvent;
import Circuit.Position;
import Sounds.SoundEffect;

class Main {
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
	final hudLayout = new LayoutFrame(CircuitRenderer.width, CircuitRenderer.surfaceHeight);
	final frameInfo = new FrameInfo(CircuitRenderer.width, CircuitRenderer.surfaceHeight,
		CircuitRenderer.width, CircuitRenderer.surfaceHeight, 1.0);
	var hudDirty = true;
	var inFlight:Null<Batch>;
	var frameToken:haxe.Int64;
	var submittedFrame = false;
	var lastWidth = 0;
	var lastHeight = 0;
	var frameSubscription:SurfaceFrameSubscription;
	final runtime:Runtime;

	var running = true;
	var frameFailure:Dynamic;
	// Keep mixer calls out of the native frame callback so audio work cannot delay presentation.
	var pendingSound:Null<SoundEffect>;

	var previousPlayer:Position;
	var previousDrone:Position;
	var lastFrame = 0.0;
	var accumulator = 0.0;

	#if circuit_run_web
	static var app:Main;

	public static function main():Void {
		var runtime = Runtime.start();
		var sounds = new Sounds();
		app = new Main(runtime, sounds);
		try app.start() catch (error:Dynamic) {
			shutdown();
			throw error;
		}
	}

	public static function poll():Int {
		if (app == null)
			return -1;
		app.iterate(false);
		if (app.frameFailure != null) {
			Sys.println("Circuit Run frame failed: " + Std.string(app.frameFailure));
			shutdown();
			return -1;
		}
		if (!app.running && app.inFlight == null) {
			shutdown();
			return 2;
		}
		return app.submittedFrame ? 1 : 0;
	}

	public static function shutdown():Void {
		if (app == null)
			return;
		if (app.inFlight != null) {
			app.running = false;
			return;
		}
		app.dispose();
		app.sounds.dispose();
		app.runtime.dispose();
		app = null;
	}
	#else
	static function main():Void {
		scoped var runtime = Runtime.start();
		scoped var sounds = new Sounds();
		var app = new Main(runtime, sounds);
		defer app.dispose();
		app.start();
		while (app.running || app.inFlight != null)
			app.iterate(true);
		if (app.frameFailure != null)
			throw app.frameFailure;
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
		hudContext.onAnimationFrameRequested = function() hudDirty = true;
		hud = new CircuitHud(game, sounds.soundEnabled, restart, toggleSound);
		surface.onReady(prepareRenderer);
		surface.onResize(function(width, _, _, _) {
			if (width > 0)
				hudBinding.setCoordinateScale(width / CircuitRenderer.width);
		});
		surface.onFrameComplete(finishFrame);
		window.onClose(function() running = false);
		window.onKey(handleKey);
		snapshotPositions();
	}

	function iterate(wait:Bool):Void {
		var hadEvent = runtime.events.poll();
		if (hadEvent) {
			for (_ in 1...64)
				if (!runtime.events.poll())
					break;
		}
		if (!hadEvent && wait && pendingSound == null)
			runtime.events.wait(0.1);
		var effect = pendingSound;
		if (running && effect != null) {
			pendingSound = null;
			sounds.play(effect);
		}
	}

	function dispose():Void {
		defer if (hudFonts != null) hudFonts.dispose();
		defer if (hudRenderer != null) hudRenderer.dispose();
		defer if (hudContext != null) hudContext.dispose();
		defer if (hudBinding != null) hudBinding.dispose();
		if (frameSubscription != null)
			frameSubscription.dispose();
	}

	function prepareRenderer():Void {
		if (renderer != null)
			return;
		try {
			renderer = new CircuitRenderer(surface);
			frameSubscription = surface.onFrame(onFrame);
		} catch (error:Dynamic) failFrame(error);
	}

	function finishFrame(token:haxe.Int64, result:Result):Void {
		var batch = inFlight;
		if (batch == null || token != frameToken)
			return;
		inFlight = null;
		batch.dispose();
		if (result == Result.Ok)
			submittedFrame = true;
		else
			failFrame("NativeKit frame result " + Std.string(result));
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
		pendingSound = null;
		snapshotPositions();
		accumulator = 0.0;
		lastFrame = 0.0;
		hudDirty = true;
	}

	function toggleSound():Void {
		sounds.toggleMute();
		hudDirty = true;
	}

	function failFrame(error:Dynamic):Void {
		frameFailure = error;
		running = false;
	}

	function onGameEvent(event:CircuitEvent):Void {
		pendingSound = switch event {
			case NodeCollected: Pickup;
			case RoundFinished(Captured): Caught;
			case RoundFinished(Cleared): Clear;
		};
		hudDirty = true;
	}

	function onFrame(width:Int, height:Int):Void {
		if (!running || inFlight != null || width <= 0 || height <= 0)
			return;
		try {
			var now = Sys.monotonicTime();
			var delta = lastFrame == 0.0 ? 0.0 : Math.min(now - lastFrame, 0.1);
			advanceSimulation(now);
			var progress = accumulator / stepSeconds;
			var player = lerp(previousPlayer, game.playerPosition(), progress);
			var drone = lerp(previousDrone, game.dronePosition(), progress);
			var frame = surface.acquireFrame();
			defer if (!frame.isFinished()) frame.cancel();
			var batch = renderer.record(game, player, drone, width, height);
			var queued = false;
			defer if (!queued) batch.dispose();
			var gpuStep = batch.frameStep();
			defer gpuStep.dispose();

			var scale = width / CircuitRenderer.width;
			var logicalHeight = height / scale;
			if (hudDirty || hudContext.isDirty() || hudContext.needsAnimationFrame
				|| width != lastWidth || height != lastHeight) {
				hudLayout.setViewport(CircuitRenderer.width, logicalHeight);
				hudLayout.deltaSeconds = delta;
				hudContext.submit(hud, hudLayout);
				hudDirty = false;
				lastWidth = width;
				lastHeight = height;
			}
			frameInfo.set(CircuitRenderer.width, logicalHeight, width, height, scale);
			var uiStep = hudContext.frameStep(hudRenderer, frame, frameInfo);
			defer uiStep.dispose();
			frame.submit([gpuStep, uiStep]);
			frameToken = frame.token();
			inFlight = batch;
			queued = true;
		} catch (error:Dynamic) {
			failFrame(error);
		}
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
