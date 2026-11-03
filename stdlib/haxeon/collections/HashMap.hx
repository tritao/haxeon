package haxeon.collections;

import haxeon.Hashing;
import Hashable;

/** Dense entries and open-addressed buckets for keys with declared value equality. */
class HashMap<K:Hashable, V> {
	var keySlots:Null<Array<K>>;
	var valueSlots:Null<Array<V>>;
	var hashes:Null<Array<Int>>;
	var buckets:Null<Array<Int>>;
	var occupied:Int;

	public function new() {
		keySlots = null;
		valueSlots = null;
		hashes = null;
		buckets = null;
		occupied = 0;
	}

	function bucketFor(key:K, hash:Int):Int {
		var currentBuckets = buckets, currentHashes = hashes, keys = keySlots;
		if (currentBuckets == null || currentHashes == null || keys == null) return -1;
		var at = hash & (currentBuckets.length - 1);
		while (currentBuckets[at] != 0) {
			var entry = currentBuckets[at] - 1;
			if (entry >= 0 && currentHashes[entry] == hash && Hashing.keyEquals(keys[entry], key)) return at;
			at = (at + 1) & (currentBuckets.length - 1);
		}
		return -1;
	}

	static function insertionBucket(buckets:Array<Int>, hash:Int):Int {
		var at = hash & (buckets.length - 1), vacant = -1;
		while (buckets[at] != 0) {
			if (buckets[at] < 0 && vacant < 0) vacant = at;
			at = (at + 1) & (buckets.length - 1);
		}
		return vacant < 0 ? at : vacant;
	}

	function rebuild(capacity:Int, keys:Array<K>, currentHashes:Array<Int>):Array<Int> {
		var next:Array<Int> = [];
		for (_ in 0...capacity) next.push(0);
		occupied = 0;
		for (entry in 0...keys.length) {
			var at = insertionBucket(next, currentHashes[entry]);
			next[at] = entry + 1;
			occupied++;
		}
		buckets = next;
		return next;
	}

	public function set(key:K, value:V):Void {
		var keys = keySlots, values = valueSlots, currentHashes = hashes, currentBuckets = buckets;
		if (currentBuckets == null) {
			keys = [];
			values = [];
			currentHashes = [];
			currentBuckets = [];
			for (_ in 0...16) currentBuckets.push(0);
			keySlots = keys;
			valueSlots = values;
			hashes = currentHashes;
			buckets = currentBuckets;
		}
		if (keys == null || values == null || currentHashes == null) throw "Invalid map storage";
		var hash = Hashing.hash(key), at = bucketFor(key, hash);
		if (at >= 0) {
			values[currentBuckets[at] - 1] = value;
			return;
		}
		if ((occupied + 1) * 2 >= currentBuckets.length)
			currentBuckets = rebuild((keys.length + 1) * 2 < currentBuckets.length ? currentBuckets.length : currentBuckets.length * 2, keys, currentHashes);
		at = insertionBucket(currentBuckets, hash);
		if (currentBuckets[at] == 0) occupied++;
		currentBuckets[at] = keys.length + 1;
		keys.push(key);
		values.push(value);
		currentHashes.push(hash);
	}

	public function get(key:K):Null<V> {
		var at = bucketFor(key, Hashing.hash(key));
		if (at < 0) return null;
		var currentBuckets = buckets, values = valueSlots;
		if (currentBuckets == null || values == null) throw "Invalid map storage";
		return values[currentBuckets[at] - 1];
	}

	public function exists(key:K):Bool return bucketFor(key, Hashing.hash(key)) >= 0;

	public function remove(key:K):Bool {
		var at = bucketFor(key, Hashing.hash(key));
		if (at < 0) return false;
		var keys = keySlots, values = valueSlots, currentHashes = hashes, currentBuckets = buckets;
		if (keys == null || values == null || currentHashes == null || currentBuckets == null) throw "Invalid map storage";
		var entry = currentBuckets[at] - 1, last = keys.length - 1;
		currentBuckets[at] = -1;
		if (entry != last) {
			var moved = currentHashes[last] & (currentBuckets.length - 1);
			while (currentBuckets[moved] != last + 1) moved = (moved + 1) & (currentBuckets.length - 1);
			currentBuckets[moved] = entry + 1;
			keys[entry] = keys[last];
			values[entry] = values[last];
			currentHashes[entry] = currentHashes[last];
		}
		keys.pop();
		values.pop();
		currentHashes.pop();
		return true;
	}

	public function clear():Void {
		var keys = keySlots, values = valueSlots, currentHashes = hashes, currentBuckets = buckets;
		if (currentBuckets == null) return;
		if (keys == null || values == null || currentHashes == null) throw "Invalid map storage";
		keys.resize(0);
		values.resize(0);
		currentHashes.resize(0);
		for (index in 0...currentBuckets.length) currentBuckets[index] = 0;
		occupied = 0;
	}

	public function size():Int { var keys = keySlots; return keys == null ? 0 : keys.length; }
	public function keys():Array<K> { var keys = keySlots; return keys == null ? [] : keys.copy(); }
	public function values():Array<V> { var values = valueSlots; return values == null ? [] : values.copy(); }

	public function copy():HashMap<K, V> {
		var result = new HashMap<K, V>(), keys = keySlots, values = valueSlots;
		if (keys == null) return result;
		if (values == null) throw "Invalid map storage";
		for (index in 0...keys.length) result.set(keys[index], values[index]);
		return result;
	}
}
