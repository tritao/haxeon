package haxe.ds;

#if wasm
/** Identity-keyed storage without HashLink handles. Wasm references have no stable identity hash. */
class ObjectMap<K, V> {
	final keys:Array<K> = [];
	final values:Array<V> = [];

	public function new() {}

	public function set(key:K, value:V):Void {
		var index = keys.indexOf(key);
		if (index < 0) {
			keys.push(key);
			values.push(value);
		} else
			values[index] = value;
	}

	public function get(key:K):Null<V> {
		var index = keys.indexOf(key);
		return index < 0 ? null : values[index];
	}

	public function exists(key:K):Bool
		return keys.indexOf(key) >= 0;

	public function remove(key:K):Bool {
		var index = keys.indexOf(key);
		if (index < 0)
			return false;
		keys.splice(index, 1);
		values.splice(index, 1);
		return true;
	}
}
#else
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

/** HashLink identity-keyed map. Keys are compared by object identity. */
class ObjectMap<K, V> {
	final handle:hl.Abstract<"hl_obj_map">;

	public function new()
		handle = objectMapAlloc();

	public function set(key:K, value:V):Void
		objectMapSet(handle, key, value);

	public function get(key:K):Null<V>
		return cast objectMapGet(handle, key);

	public function exists(key:K):Bool
		return objectMapExists(handle, key);

	public function remove(key:K):Bool
		return objectMapRemove(handle, key);
}
#end
