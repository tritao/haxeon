package haxeon.ui;

/**
 * Maps integer keys to non-negative integers without allocating per `set` or `get`: `Map<Int, Int>` boxes both the value it
 * stores and the one it returns. Open addressing over three arrays; `clear` bumps a generation instead of touching the slots.
 */
class IntIndex {
	var keys:Array<Int>;
	var values:Array<Int>;
	var stamps:Array<Int>;
	var generation:Int = 1;
	var mask:Int;
	var used:Int = 0;

	public function new(capacity:Int = 256) {
		var size = 16;
		while (size < capacity)
			size <<= 1;
		keys = [for (_ in 0...size) 0];
		values = [for (_ in 0...size) 0];
		stamps = [for (_ in 0...size) 0];
		mask = size - 1;
	}

	/** The value stored for `key`, or -1 when there is none. */
	public function get(key:Int):Int {
		var slot = (key ^ (key >>> 15)) & mask;
		while (stamps[slot] == generation) {
			if (keys[slot] == key)
				return values[slot];
			slot = (slot + 1) & mask;
		}
		return -1;
	}

	/** Stores a non-negative `value`, replacing any earlier one for `key`. */
	public function set(key:Int, value:Int):Void {
		var slot = (key ^ (key >>> 15)) & mask;
		while (stamps[slot] == generation) {
			if (keys[slot] == key) {
				values[slot] = value;
				return;
			}
			slot = (slot + 1) & mask;
		}
		if ((used + 1) * 2 > mask + 1) {
			grow();
			set(key, value);
			return;
		}
		keys[slot] = key;
		values[slot] = value;
		stamps[slot] = generation;
		used++;
	}

	public function clear():Void {
		generation++;
		used = 0;
	}

	function grow():Void {
		var oldKeys = keys, oldValues = values, oldStamps = stamps, oldGeneration = generation;
		var size = (mask + 1) * 2;
		keys = [for (_ in 0...size) 0];
		values = [for (_ in 0...size) 0];
		stamps = [for (_ in 0...size) 0];
		mask = size - 1;
		generation = 1;
		used = 0;
		for (index in 0...oldKeys.length)
			if (oldStamps[index] == oldGeneration)
				set(oldKeys[index], oldValues[index]);
	}
}
