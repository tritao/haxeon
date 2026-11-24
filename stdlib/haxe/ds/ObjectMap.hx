package haxe.ds;

#if !wasm
@:hlNative("std", "hoalloc")
extern function objectMapAlloc():hl.Abstract<"hl_obj_map">;

@:hlNative("std", "hoset")
extern function objectMapSet(map:hl.Abstract<"hl_obj_map">, key:Dynamic, value:Dynamic):Void;

@:hlNative("std", "hoget")
extern function objectMapGet(map:hl.Abstract<"hl_obj_map">, key:Dynamic):Dynamic;

@:hlNative("std", "hoexists")
extern function objectMapExists(map:hl.Abstract<"hl_obj_map">, key:Dynamic):Bool;

@:hlNative("std", "horemove")
extern function objectMapRemove(map:hl.Abstract<"hl_obj_map">, key:Dynamic):Bool;

@:hlNative("std", "hokeys")
extern function objectMapKeys(map:hl.Abstract<"hl_obj_map">):Array<Dynamic>;

@:hlNative("std", "hovalues")
extern function objectMapValues(map:hl.Abstract<"hl_obj_map">):Array<Dynamic>;

@:hlNative("std", "hoclear")
extern function objectMapClear(map:hl.Abstract<"hl_obj_map">):Void;

@:hlNative("std", "hosize")
extern function objectMapSize(map:hl.Abstract<"hl_obj_map">):Int;

#end

/** Keys are compared by object identity. */
class ObjectMap<K, V> {
	#if wasm
	// Wasm references have no stable identity hash.
	final keyStorage:Array<K> = [];
	final valueStorage:Array<V> = [];

	public function new() {}

	function indexOf(key:K):Int {
		for (index in 0...keyStorage.length)
			if (__reference_equal(keyStorage[index], key))
				return index;
		return -1;
	}

	public function set(key:K, value:V):Void {
		var index = indexOf(key);
		if (index < 0) {
			keyStorage.push(key);
			valueStorage.push(value);
		} else
			valueStorage[index] = value;
	}

	public function get(key:K):Null<V> {
		var index = indexOf(key);
		return index < 0 ? null : valueStorage[index];
	}

	public function exists(key:K):Bool
		return indexOf(key) >= 0;

	@:noCompletion public function keyArray():Array<K>
		return keyStorage.copy();

	@:noCompletion public function valueArray():Array<V>
		return valueStorage.copy();

	public function clear():Void {
		keyStorage.resize(0);
		valueStorage.resize(0);
	}

	@:noCompletion public function size():Int
		return keyStorage.length;

	public function toString():String
		return Std.formatMapEntries(keyStorage.copy().iterator(), valueStorage.copy().iterator());

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

	public function new()
		handle = objectMapAlloc();

	public function set(key:K, value:V):Void
		objectMapSet(handle, key, value);

	public function get(key:K):Null<V> {
		var value = objectMapGet(handle, key);
		return value == null ? null : stored(value);
	}

	/**
	 * A value the table holds, as the `V` it was stored as. The cast is made in a body shared by every reference type, so the
	 * value crosses back as itself, where a cast to a structure type would copy it into a new record.
	 */
	static function stored<T>(value:Dynamic):T
		return cast value;

	public function exists(key:K):Bool
		return objectMapExists(handle, key);

	@:noCompletion public function keyArray():Array<K>
		return cast objectMapKeys(handle);

	@:noCompletion public function valueArray():Array<V>
		return cast objectMapValues(handle);

	public function clear():Void
		objectMapClear(handle);

	@:noCompletion public function size():Int
		return objectMapSize(handle);

	public function toString():String
		return Std.formatMapEntries(objectMapKeys(handle).iterator(), objectMapValues(handle).iterator());

	public function remove(key:K):Bool
		return objectMapRemove(handle, key);
	#end

	public function keys():Iterator<K>
		return keyArray().iterator();

	public function iterator():Iterator<V>
		return valueArray().iterator();

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

	public function copy():ObjectMap<K, V> {
		var result = new ObjectMap<K, V>();
		for (key in keys())
			result.set(key, cast get(key));
		return result;
	}
}
