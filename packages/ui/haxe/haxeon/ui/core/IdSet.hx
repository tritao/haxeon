package haxeon.ui.core;

/**
 * A set of integer IDs that allocates nothing per insert or clear. `Map<Int, Bool>` boxes its value on every `set`, and these sets
 * are filled for every node of every frame. Open addressing over two arrays; `clear` bumps a generation instead of touching the
 * slots, so it is constant time whatever the size.
 */
class IdSet {
	var keys:Array<Int>;
	var stamps:Array<Int>;
	var generation:Int = 1;
	var mask:Int;
	var used:Int = 0;

	public function new(capacity:Int = 1024) {
		var size = 16;
		while (size < capacity)
			size <<= 1;
		keys = [for (_ in 0...size) 0];
		stamps = [for (_ in 0...size) 0];
		mask = size - 1;
	}

	public function has(id:Int):Bool {
		var slot = (id ^ (id >>> 15)) & mask;
		while (stamps[slot] == generation) {
			if (keys[slot] == id)
				return true;
			slot = (slot + 1) & mask;
		}
		return false;
	}

	/** Adds `id` and returns whether it was not already present. */
	public function add(id:Int):Bool {
		var slot = (id ^ (id >>> 15)) & mask;
		while (stamps[slot] == generation) {
			if (keys[slot] == id)
				return false;
			slot = (slot + 1) & mask;
		}
		if ((used + 1) * 2 > mask + 1) {
			grow();
			return add(id);
		}
		keys[slot] = id;
		stamps[slot] = generation;
		used++;
		return true;
	}

	public function clear():Void {
		generation++;
		used = 0;
	}

	function grow():Void {
		var oldKeys = keys, oldStamps = stamps, oldGeneration = generation;
		var size = (mask + 1) * 2;
		keys = [for (_ in 0...size) 0];
		stamps = [for (_ in 0...size) 0];
		mask = size - 1;
		generation = 1;
		used = 0;
		for (index in 0...oldKeys.length)
			if (oldStamps[index] == oldGeneration)
				add(oldKeys[index]);
	}
}
