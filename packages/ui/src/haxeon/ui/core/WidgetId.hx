package haxeon.ui.core;

import haxeon.ui.core.RenderScope;

/** Stable 31-bit identity used to reconnect ephemeral widgets across frames. */
class WidgetId {
	/** The id as a number, stable across frames for the same key path. */
	public final value:Int;

	/** The id `value`; `BuildContext.id` and `KeyScope.widgetId` make the ids of keyed widgets. */
	public function new(value:Int) {
		if (value <= 0)
			throw "Widget IDs must be positive 31-bit values";
		this.value = value;
	}

	/** Whether `other` names the same widget. */
	public inline function equals(other:WidgetId):Bool
		return other != null && value == other.value;

	/** The id as text, for diagnostics. */
	public function toString():String
		return Std.string(value);
}

/** A scalar ownership-list entry. The low bit is the domain; the sign is payload. */
internal abstract ResourceId(Int) {
	@:allow(haxeon.ui.core.StateStore) inline function new(value:Int) this = value;

	public static inline function widget(id:WidgetId):ResourceId return new ResourceId(id.value << 1);
	internal static inline function scope(id:ScopeResourceId):ResourceId return new ResourceId((id.rawValue() << 1)
		| 1);

	public inline function rawValue():Int return this;
	public inline function isScope():Bool return (this & 1) != 0;

	@:allow(haxeon.ui.core.StateStore) inline function payload():Int return this >>> 1;
	@:allow(haxeon.ui.core.StateStore) inline function scopeId():ScopeResourceId return new ScopeResourceId(this >>> 1);
}

/** Sorted path/ID pairs. Removing recycled rows compacts live pairs without growing a map freelist. */
internal class WidgetIdCache {
	final paths:Array<Null<String>> = [];
	final ids:Array<Null<WidgetId>> = [];
	public var count(default, null):Int = 0;
	/** High-water storage slots, retained across prune and clear rather than trimmed and regrown. */
	public var storageSlots(get, never):Int;
	inline function get_storageSlots():Int return paths.length;

	public function new() {}

	public function get(path:String):Null<WidgetId> {
		var position = find(path);
		return position < 0 ? null : ids[position];
	}

	public function exists(path:String):Bool return find(path) >= 0;

	public function set(path:String, id:WidgetId):Void {
		if (path == null || id == null) throw "A widget ID cache entry needs a path and identity";
		var position = find(path);
		if (position >= 0) {
			ids[position] = id;
			return;
		}
		position = -position - 1;
		if (count == paths.length) {
			paths.push(null);
			ids.push(null);
		}
		var index = count;
		while (index > position) {
			paths[index] = paths[index - 1];
			ids[index] = ids[index - 1];
			index--;
		}
		paths[position] = path;
		ids[position] = id;
		count++;
	}

	public function clear():Void {
		for (index in 0...count) {
			paths[index] = null;
			ids[index] = null;
		}
		count = 0;
	}

	/** Preserve sorted order and release stale references without resizing either backing array. */
	public function prune(mounted:Map<Int, RenderNode>, states:StateStore):Void {
		var retained = states.retainedWidgetIds(mounted);
		var previous = count, write = 0;
		for (read in 0...previous) {
			var id = ids[read];
			if (id != null && (mounted.exists(id.value) || states.contains(id) || retained.has(id.value))) {
				if (write != read) {
					paths[write] = paths[read];
					ids[write] = id;
				}
				write++;
			}
		}
		for (index in write...previous) {
			paths[index] = null;
			ids[index] = null;
		}
		count = write;
	}

	/** A miss encodes its insertion position as -index-1; lookups allocate no nullable scalar box. */
	function find(path:String):Int {
		var low = 0, high = count;
		while (low < high) {
			var middle = low + ((high - low) >> 1);
			var current = paths[middle];
			if (current == null) throw "A live widget ID cache entry has no path";
			var comparison = Reflect.compare(current, path);
			if (comparison == 0) return middle;
			if (comparison < 0) low = middle + 1;
			else high = middle;
		}
		return -low - 1;
	}
}

/**
 * A set of integer IDs that allocates nothing per insert or clear. `Map<Int, Bool>` boxes its value on every `set`, and these sets
 * are filled for every node of every frame. Open addressing over two arrays; `clear` bumps a generation instead of touching the
 * slots, so it is constant time whatever the size.
 */
internal class IdSet {
	var keys:Array<Int>;
	var stamps:Array<Int>;
	var generation:Int = 1;
	var mask:Int;
	var used:Int = 0;

	public function new(capacity:Int = 1024) {
		var size = 16;
		while (size < capacity) size <<= 1;
		keys = [for (_ in 0...size) 0];
		stamps = [for (_ in 0...size) 0];
		mask = size - 1;
	}

	public function has(id:Int):Bool {
		var slot = (id ^ (id >>> 15)) & mask;
		while (stamps[slot] == generation) {
			if (keys[slot] == id) return true;
			slot = (slot + 1) & mask;
		}
		return false;
	}

	/** Adds `id` and returns whether it was not already present. */
	public function add(id:Int):Bool {
		var slot = (id ^ (id >>> 15)) & mask;
		while (stamps[slot] == generation) {
			if (keys[slot] == id) return false;
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

	public function count():Int return used;

	/** Repair the following probe cluster in place; deletion needs no tombstones or allocations. */
	public function remove(id:Int):Bool {
		var slot = (id ^ (id >>> 15)) & mask;
		while (stamps[slot] == generation) {
			if (keys[slot] == id) {
				stamps[slot] = 0;
				used--;
				var next = (slot + 1) & mask;
				while (stamps[next] == generation) {
					var key = keys[next];
					stamps[next] = 0;
					used--;
					add(key);
					next = (next + 1) & mask;
				}
				return true;
			}
			slot = (slot + 1) & mask;
		}
		return false;
	}

	function grow():Void {
		var oldKeys = keys, oldStamps = stamps, oldGeneration = generation;
		var size = (mask + 1) * 2;
		keys = [for (_ in 0...size) 0];
		stamps = [for (_ in 0...size) 0];
		mask = size - 1;
		generation = 1;
		used = 0;
		for (index in 0...oldKeys.length) if (oldStamps[index] == oldGeneration) add(oldKeys[index]);
	}
}
