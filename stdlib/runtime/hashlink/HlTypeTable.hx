package runtime.hashlink;

import runtime.memory.RawPtr;

/** Append-only native pointer table for stable HashLink type metadata. */
class HlTypeTable {
	public final arena:HlTypeArena;
	final initialCapacity:Int;
	var entries:RawPtr<RawPtr<HlType>>;
	var capacity:Int = 0;
	var count:Int = 0;

	public function new(arena:HlTypeArena, ?initialCapacity:Int = 8) {
		if (initialCapacity <= 0)
			throw "HashLink type table capacity must be positive";
		this.arena = arena;
		this.initialCapacity = initialCapacity;
		entries = RawPtr.nullPtr();
	}

	/** Number of published type pointers in this table. */
	public inline function length():Int
		return count;

	/** Current native pointer-table capacity. */
	public inline function capacityOf():Int
		return capacity;

	/** Address of the contiguous native type-pointer table, or null when empty. */
	public inline function pointer():RawPtr<RawPtr<HlType>>
		return entries;

	/** Append one type pointer and return its stable table index. */
	public function add(type:RawPtr<HlType>):Int {
		ensureCapacity(count + 1);
		var index = count++;
		entries.offset(index).store(type);
		return index;
	}

	/** Replace one table slot without moving any metadata record. */
	public function set(index:Int, type:RawPtr<HlType>):Void {
		checkIndex(index);
		entries.offset(index).store(type);
	}

	/** Read one published type pointer. */
	public function get(index:Int):RawPtr<HlType> {
		checkIndex(index);
		return entries.offset(index).load();
	}

	/** Return the module-local index of a type pointer, or -1 when it is external. */
	public function indexOf(type:RawPtr<HlType>):Int {
		for (index in 0...count)
			if (entries.offset(index).load() == type)
				return index;
		return -1;
	}

	function ensureCapacity(required:Int):Void {
		if (required <= capacity)
			return;
		var next = capacity == 0 ? initialCapacity : capacity;
		while (next < required) {
			if (next > 0x3FFFFFFF)
				throw "HashLink type table capacity exceeds the supported range";
			next *= 2;
		}
		var grown = arena.allocTypePointerArray(next);
		for (index in 0...count)
			grown.offset(index).store(entries.offset(index).load());
		entries = grown;
		capacity = next;
	}

	function checkIndex(index:Int):Void
		if (index < 0 || index >= count)
			throw 'HashLink type table index $index is outside 0...$count';
}
