import haxeon.gpu.FrameTick;
import haxeon.gpu.Surface;
import haxeon.ui.host.DesktopUiSurface;
import haxeon.platform.Runtime;
import haxeon.platform.event.PlatformEvent;
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
	var hud:DesktopUiSurface;

	var running = true;
	var surfaceReady = false;
	var frameFailure:Dynamic;
	// Keep mixer calls out of the native frame callback so audio work cannot delay presentation.
	var pendingSound:Null<SoundEffect>;

	var previousPlayer:Position;
	var previousDrone:Position;
	var lastFrame = 0.0;
	var accumulator = 0.0;

	static function main():Void {
		var runtime = Runtime.start();
		defer runtime.dispose();
		var sounds = new Sounds();
		defer sounds.dispose();
		new Main(sounds).run(runtime);
	}

	function new(sounds:Sounds) {
		this.sounds = sounds;
	}

	function run(runtime:Runtime):Void {
		var options = new WindowOptions(CircuitRenderer.width, CircuitRenderer.height + CircuitHud.height);
		options.title = "Circuit Run | Arrows to steer, R to restart, M to mute";
		var window = runtime.createWindow(options);
		surface = Surface.create(window, CircuitRenderer.width, CircuitRenderer.height);
		surface.setBounds(0, CircuitHud.height,
			CircuitRenderer.width, CircuitRenderer.height);
		runtime.events.listen(onPlatformEvent);
		var hudView = new CircuitHud(game, sounds.soundEnabled, restart, toggleSound);
		hud = DesktopUiSurface.mount(window, runtime.events, CircuitRenderer.width, CircuitHud.height, hudView,
			failFrame);

		while (running && !surfaceReady) {
			if (!runtime.events.poll())
				runtime.events.wait(0.1);
		}
		if (frameFailure != null)
			throw frameFailure;
		if (!running)
			return;

		renderer = new CircuitRenderer(surface);
		snapshotPositions();
		surface.onFrame(onFrame);
		while (running) {
			if (!runtime.events.poll() && running && pendingSound == null)
				runtime.events.wait(0.1);
			var effect = pendingSound;
			if (running && effect != null) {
				pendingSound = null;
				sounds.play(effect);
			}
		}
		if (frameFailure != null)
			throw frameFailure;
	}

	function onPlatformEvent(event:PlatformEvent):Void {
		switch event {
			case SurfaceReady(source) if (surface.ownsEventSource(source)): surfaceReady = true;
			case WindowClose(_): running = false;
			case Key(_, key, _, action, _) if (action == InputAction.Press):
				switch key {
					case Key.Right: game.steer(East);
					case Key.Down: game.steer(South);
					case Key.Left: game.steer(West);
					case Key.Up: game.steer(North);
					case Key.R: restart();
					case Key.M: toggleSound();
					case Key.Escape: running = false;
					case _:
				}
			case _:
		}
	}

	function restart():Void {
		game.reset();
		pendingSound = null;
		snapshotPositions();
		accumulator = 0.0;
		lastFrame = 0.0;
		hud.invalidate();
	}

	function toggleSound():Void {
		sounds.toggleMute();
		hud.invalidate();
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
		hud.invalidate();
	}

	function onFrame(frame:FrameTick):Void {
		if (!running)
			return;
		try {
			advanceSimulation(frame.timeSeconds);
			var progress = accumulator / stepSeconds;
			var player = lerp(previousPlayer, game.playerPosition(), progress);
			var drone = lerp(previousDrone, game.dronePosition(), progress);
			renderer.draw(game, player, drone);
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
