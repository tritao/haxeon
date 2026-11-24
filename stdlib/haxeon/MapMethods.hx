package haxeon;

/**
	Map methods written in Haxe instead of built into the compiler. A call `map.name(arguments)` that the compiler does not
	implement natively is typed as `MapMethods.name(map, arguments)`, so adding a map method means adding a generic function here.
**/
class MapMethods {
	/**
		The map's entries as `{key, value}`, as Haxe's `haxe.iterators.MapKeyValueIterator` gives them: the keys as `keys()` lists
		them, each with its value read when the entry is reached.
	**/
	public static function keyValueIterator<K, V>(map:Map<K, V>):KeyValueIterator<K, V> {
		var keys = map.keys();
		return {hasNext: () -> keys.hasNext(),
			next: () -> {
				var key = keys.next();
				var value:V = cast map.get(key);
				return {key: key, value: value};
			}
		};
	}
}
