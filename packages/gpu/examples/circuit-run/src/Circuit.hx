typedef Position = {
	final x:Float;
	final y:Float;
}

enum Direction {
	East;
	South;
	West;
	North;
	Stopped;
}

enum Tile {
	Wall;
	Floor;
	Node;
}

enum RoundOutcome {
	Captured;
	Cleared;
}

enum RoundState {
	Playing;
	Finished(outcome:RoundOutcome);
}

enum CircuitEvent {
	NodeCollected;
	RoundFinished(outcome:RoundOutcome);
}

/** Owns the maze, steering, pursuit, and round rules. */
class Circuit {
	static final travelDirections = [East, South, West, North];
	// The neighbor search relies on a solid wall border around the 15×11 layout.
	static final layout = [
		"###############",
		"#P....#.......#",
		"#.##..#.###.#.#",
		"#....##.....#.#",
		"###......##...#",
		"#...###.....#.#",
		"#.#.....###...#",
		"#...##......#.#",
		"#.#....##.....#",
		"#...#.....##.D#",
		"###############"
	];

	public static inline var width = 15;
	public static inline var height = 11;
	public static inline var ticksPerSecond = 120;

	static inline var playerStepsPerTile = 17;
	static inline var droneStepsPerTile = 51;
	static inline var captureDistance = 0.6;
	static inline var captureDistanceSquared = captureDistance * captureDistance;

	var player:Actor;
	var drone:Actor;
	public var remaining(default, null):Int;
	public var state(default, null):RoundState;

	var cells:Array<Tile>;
	var heading:Direction;
	var queued:Direction;

	public function new() reset();

	public function reset():Void {
		cells = [];
		remaining = 0;
		state = Playing;
		heading = Stopped;
		queued = Stopped;
		var playerStart = 0;
		var droneStart = 0;
		for (row in layout) {
			for (x in 0...width) {
				var tile = switch row.charAt(x) {
					case "#": Wall;
					case ".":
						remaining++;
						Node;
					case "P":
						playerStart = cells.length;
						Floor;
					case "D":
						droneStart = cells.length;
						Floor;
					case _: Floor;
				};
				cells.push(tile);
			}
		}
		player = new Actor(playerStart, width, playerStepsPerTile);
		drone = new Actor(droneStart, width, droneStepsPerTile);
	}

	public function tile(index:Int):Tile return cells[index];

	public function steer(direction:Direction):Void queued = direction;

	static function neighbor(index:Int, direction:Direction):Int {
		return index + switch direction {
			case East: 1;
			case South: width;
			case West: -1;
			case North: -width;
			case Stopped: 0;
		};
	}

	public function playerPosition():Position return {x: player.x(), y: player.y()};
	public function dronePosition():Position return {x: drone.x(), y: drone.y()};

	/** Advances one simulation tick and emits transitions in gameplay order. */
	public function step(emit:CircuitEvent->Void):Void {
		if (state != Playing || (queued == Stopped && heading == Stopped))
			return;

		if (player.atCenter()) {
			if (queued != Stopped && cells[neighbor(player.tile, queued)] != Wall) {
				heading = queued;
				queued = Stopped;
			}
			var next = neighbor(player.tile, heading);
			if (cells[next] != Wall)
				player.moveTo(next);
		}

		var pickedUpNode = player.advance() && cells[player.tile] == Node;
		if (pickedUpNode) {
			cells[player.tile] = Floor;
			remaining--;
		}

		if (drone.atCenter())
			drone.moveTo(pursue(player.target));
		drone.advance();

		var dx = player.x() - drone.x();
		var dy = player.y() - drone.y();
		if (dx * dx + dy * dy < captureDistanceSquared)
			finish(Captured, emit);
		else if (remaining == 0)
			finish(Cleared, emit);
		else if (pickedUpNode)
			emit(NodeCollected);
	}

	function finish(outcome:RoundOutcome, emit:CircuitEvent->Void):Void {
		state = Finished(outcome);
		emit(RoundFinished(outcome));
	}

	function pursue(target:Int):Int {
		// Search from the player’s target tile back to the drone to find its next step.
		var visited = [for (_ in 0...cells.length) false];
		if (target == drone.tile)
			return drone.tile;
		var queue = [target];
		visited[target] = true;
		var head = 0;
		while (head < queue.length) {
			var current = queue[head++];
			for (direction in travelDirections) {
				var next = neighbor(current, direction);
				if (next == drone.tile)
					return current;
				if (!visited[next] && cells[next] != Wall) {
					visited[next] = true;
					queue.push(next);
				}
			}
		}
		return drone.tile;
	}
}

/** Moves one grid occupant between adjacent tile centers over a fixed number of ticks. */
private class Actor {
	public var tile(default, null):Int;
	public var target(default, null):Int;

	final rowWidth:Int;
	final stepsPerTile:Int;
	var progress = 0;

	public function new(tile:Int, rowWidth:Int, stepsPerTile:Int) {
		this.tile = tile;
		this.target = tile;
		this.rowWidth = rowWidth;
		this.stepsPerTile = stepsPerTile;
	}

	public function atCenter():Bool return tile == target;

	public function moveTo(next:Int):Void target = next;

	/** Returns true when this tick reaches a new tile center. */
	public function advance():Bool {
		if (atCenter())
			return false;
		progress++;
		if (progress < stepsPerTile)
			return false;
		tile = target;
		progress = 0;
		return true;
	}

	public function x():Float
		return interpolate(tile % rowWidth, target % rowWidth);

	public function y():Float
		return interpolate(Std.int(tile / rowWidth), Std.int(target / rowWidth));

	inline function interpolate(from:Int, to:Int):Float
		return from + (to - from) * progress / stepsPerTile;
}
