package haxeon.collections;

import haxeon.Hashing;
import Hashable;

/** Dense entries and open-addressed buckets for keys with declared value equality. */
class HashMap<K:Hashable, V> {
	var keySlots:Array<K>;
	var valueSlots:Array<V>;
	var hashes:Array<Int>;
	var buckets:Array<Int>;
	var occupied:Int;

	public function new() {
		keySlots = [];
		valueSlots = [];
		hashes = [];
		buckets = [];
		for (_ in 0...16) buckets.push(0);
		occupied = 0;
	}

	function bucketFor(key:K, hash:Int):Int {
		var at = hash & (buckets.length - 1);
		while (buckets[at] != 0) {
			var entry = buckets[at] - 1;
			if (entry >= 0 && hashes[entry] == hash && keySlots[entry] == key) return at;
			at = (at + 1) & (buckets.length - 1);
		}
		return -1;
	}

	function insertionBucket(hash:Int):Int {
		var at = hash & (buckets.length - 1), vacant = -1;
		while (buckets[at] != 0) {
			if (buckets[at] < 0 && vacant < 0) vacant = at;
			at = (at + 1) & (buckets.length - 1);
		}
		return vacant < 0 ? at : vacant;
	}

	function rebuild(capacity:Int):Void {
		buckets = [];
		for (_ in 0...capacity) buckets.push(0);
		occupied = 0;
		for (entry in 0...keySlots.length) {
			var at = insertionBucket(hashes[entry]);
			buckets[at] = entry + 1;
			occupied++;
		}
	}

	public function set(key:K, value:V):Void {
		var hash = Hashing.hash(key), at = bucketFor(key, hash);
		if (at >= 0) {
			valueSlots[buckets[at] - 1] = value;
			return;
		}
		if ((occupied + 1) * 2 >= buckets.length)
			rebuild((keySlots.length + 1) * 2 < buckets.length ? buckets.length : buckets.length * 2);
		at = insertionBucket(hash);
		if (buckets[at] == 0) occupied++;
		buckets[at] = keySlots.length + 1;
		keySlots.push(key);
		valueSlots.push(value);
		hashes.push(hash);
	}

	public function get(key:K):Null<V> {
		var at = bucketFor(key, Hashing.hash(key));
		return at < 0 ? null : valueSlots[buckets[at] - 1];
	}

	public function exists(key:K):Bool return bucketFor(key, Hashing.hash(key)) >= 0;

	public function remove(key:K):Bool {
		var at = bucketFor(key, Hashing.hash(key));
		if (at < 0) return false;
		var entry = buckets[at] - 1, last = keySlots.length - 1;
		buckets[at] = -1;
		if (entry != last) {
			var moved = hashes[last] & (buckets.length - 1);
			while (buckets[moved] != last + 1) moved = (moved + 1) & (buckets.length - 1);
			buckets[moved] = entry + 1;
			keySlots[entry] = keySlots[last];
			valueSlots[entry] = valueSlots[last];
			hashes[entry] = hashes[last];
		}
		keySlots.pop();
		valueSlots.pop();
		hashes.pop();
		return true;
	}

	public function clear():Void {
		keySlots.resize(0);
		valueSlots.resize(0);
		hashes.resize(0);
		for (index in 0...buckets.length) buckets[index] = 0;
		occupied = 0;
	}

	public function size():Int return keySlots.length;
	public function keys():Array<K> return keySlots.copy();
	public function values():Array<V> return valueSlots.copy();

	public function copy():HashMap<K, V> {
		var result = new HashMap<K, V>();
		for (index in 0...keySlots.length) result.set(keySlots[index], valueSlots[index]);
		return result;
	}
}
