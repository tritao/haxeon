package haxe.ds;

#if !wasm
@:hlNative("std", "hoalloc")
internal extern function objectMapAlloc():hl.Abstract<"hl_obj_map">;

@:hlNative("std", "hoset")
internal extern function objectMapSet(map:hl.Abstract<"hl_obj_map">, key:Dynamic, value:Dynamic):Void;

@:hlNative("std", "hoget")
internal extern function objectMapGet(map:hl.Abstract<"hl_obj_map">, key:Dynamic):Dynamic;

@:hlNative("std", "hoexists")
internal extern function objectMapExists(map:hl.Abstract<"hl_obj_map">, key:Dynamic):Bool;

@:hlNative("std", "horemove")
internal extern function objectMapRemove(map:hl.Abstract<"hl_obj_map">, key:Dynamic):Bool;

@:hlNative("std", "hokeys")
internal extern function objectMapKeys(map:hl.Abstract<"hl_obj_map">):Array<Dynamic>;

@:hlNative("std", "hovalues")
internal extern function objectMapValues(map:hl.Abstract<"hl_obj_map">):Array<Dynamic>;

@:hlNative("std", "hoclear")
internal extern function objectMapClear(map:hl.Abstract<"hl_obj_map">):Void;

@:hlNative("std", "hosize")
internal extern function objectMapSize(map:hl.Abstract<"hl_obj_map">):Int;

#end

/** A map whose keys are objects, compared by identity: two equal objects are two keys. `Map` with an object key type is one. */
class ObjectMap<K, V> {
	#if wasm
	// Wasm references have no stable identity hash.
	final keyStorage:Array<K> = [];
	final valueStorage:Array<V> = [];

	/** An empty map. */
	public function new() {}

	function indexOf(key:K):Int {
		for (index in 0...keyStorage.length)
			if (__reference_equal(keyStorage[index], key))
				return index;
		return -1;
	}

	/** Maps `key` to `value`, replacing what it mapped to. */
	public function set(key:K, value:V):Void {
		var index = indexOf(key);
		if (index < 0) {
			keyStorage.push(key);
			valueStorage.push(value);
		} else
			valueStorage[index] = value;
	}

	/** What `key` maps to, or null when it maps to nothing. */
	public function get(key:K):Null<V> {
		var index = indexOf(key);
		return index < 0 ? null : valueStorage[index];
	}

	/** Whether `key` maps to a value. */
	public function exists(key:K):Bool
		return indexOf(key) >= 0;

	/** The keys, in a new array. */
	@:noCompletion public function keyArray():Array<K>
		return keyStorage.copy();

	/** The values, in a new array, in the order of `keyArray`. */
	@:noCompletion public function valueArray():Array<V>
		return valueStorage.copy();

	/** Removes every key. */
	public function clear():Void {
		keyStorage.resize(0);
		valueStorage.resize(0);
	}

	/** How many keys the map has. */
	@:noCompletion public function size():Int
		return keyStorage.length;

	/** The map as `[key => value, ...]`. */
	public function toString():String
		return Std.formatMapEntries(keyStorage.copy().iterator(), valueStorage.copy().iterator());

	/** Removes `key`. Returns whether it mapped to a value. */
	public function remove(key:K):Bool {
		var index = indexOf(key);
		if (index < 0)
			return false;
		keyStorage.splice(index, 1);
		valueStorage.splice(index, 1);
		return true;
	}
	#else
	final handle:hl.Abstract<"hl_obj_map">;

	/** An empty map. */
	public function new()
		handle = objectMapAlloc();

	/** Maps `key` to `value`, replacing what it mapped to. */
	public function set(key:K, value:V):Void
		objectMapSet(handle, key, value);

	/** What `key` maps to, or null when it maps to nothing. */
	public function get(key:K):Null<V>
		return cast objectMapGet(handle, key);

	/** Whether `key` maps to a value. */
	public function exists(key:K):Bool
		return objectMapExists(handle, key);

	/** The keys, in a new array. */
	@:noCompletion public function keyArray():Array<K>
		return cast objectMapKeys(handle);

	/** The values, in a new array, in the order of `keyArray`. */
	@:noCompletion public function valueArray():Array<V>
		return cast objectMapValues(handle);

	/** Removes every key. */
	public function clear():Void
		objectMapClear(handle);

	/** How many keys the map has. */
	@:noCompletion public function size():Int
		return objectMapSize(handle);

	/** The map as `[key => value, ...]`. */
	public function toString():String
		return Std.formatMapEntries(objectMapKeys(handle).iterator(), objectMapValues(handle).iterator());

	/** Removes `key`. Returns whether it mapped to a value. */
	public function remove(key:K):Bool
		return objectMapRemove(handle, key);
	#end

	/** The keys, as they were when it was called. */
	public function keys():Iterator<K>
		return keyArray().iterator();

	/** The values, as they were when it was called. */
	public function iterator():Iterator<V>
		return valueArray().iterator();

	/** Each key with its value, for `for (key => value in map)`. The keys are those when it was called. */
	public function keyValueIterator():KeyValueIterator<K, V> {
		var snapshot = keys();
		return {hasNext: () -> snapshot.hasNext(),
			next: () -> {
				var key = snapshot.next();
				var value:V = cast get(key);
				return {key: key, value: value};
			}
		};
	}

	/** A new map with the same keys and values. */
	public function copy():ObjectMap<K, V> {
		var result = new ObjectMap<K, V>();
		for (key in keys())
			result.set(key, cast get(key));
		return result;
	}
}
