package haxe.ds;

@:hlNative("std", "hoalloc")
extern function objectMapAlloc():hl.Abstract<"hl_obj_map">;

@:hlNative("std", "hoset")
extern function objectMapSet(map:hl.Abstract<"hl_obj_map">, key:Dynamic, value:Dynamic):Void;

@:hlNative("std", "hoget")
extern function objectMapGet(map:hl.Abstract<"hl_obj_map">, key:Dynamic):Dynamic;

@:hlNative("std", "hoexists")
extern function objectMapExists(map:hl.Abstract<"hl_obj_map">, key:Dynamic):Bool;

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
}
