package runtime.memory;

/** Owning open-addressed map for integer keys and fixed-layout native values. */
class NativeIntMap<V> {
	public final arena:Arena;
	public var length(default, null):Int = 0;
	public var capacity(default, null):Int = 0;

	var keys:RawPtr<Int32>;
	var values:RawPtr<V>;
	var occupied:RawPtr<UInt8>;
	var minimumCapacity:Int;
	var disposed:Bool = false;

	public function new(?initialCapacity:Int = 8) {
		if (initialCapacity < 0)
			throw "Native integer map capacity must be non-negative";
		arena = new Arena();
		keys = RawPtr.nullPtr();
		values = RawPtr.nullPtr();
		occupied = RawPtr.nullPtr();
		minimumCapacity = initialCapacity;
	}

	/** Ensure enough slots for required entries while keeping load below 70%. */
	public function reserve(required:Int):Void {
		if (disposed)
			throw "Native integer map is already disposed";
		if (required < 0)
			throw "Native integer map size must be non-negative";
		var minimum = required > minimumCapacity ? required : minimumCapacity;
		if (capacity > 0 && minimum * 10 <= capacity * 7)
			return;
		var next = capacity == 0 ? 1 : capacity;
		while (next < minimum || next * 7 < minimum * 10) {
			if (next > 0x1FFFFFFF)
				throw "Native integer map capacity exceeds the supported range";
			next *= 2;
		}
		var newKeys:RawPtr<Int32> = arena.alloc(next), newValues:RawPtr<V> = arena.alloc(next), newOccupied:RawPtr<UInt8> = arena.alloc(next);
		for (index in 0...next)
			newOccupied.offset(index).store(cast 0);
		if (capacity > 0)
			for (index in 0...capacity)
				if (occupiedAt(occupied, index) != 0) {
					var key = keyAt(keys, index), slot = hash(key) & (next - 1);
					while (occupiedAt(newOccupied, slot) != 0)
						slot = (slot + 1) & (next - 1);
					newKeys.offset(slot).store(cast key);
					newValues.offset(slot).store(values.offset(index).load());
					newOccupied.offset(slot).store(cast 1);
				}
		keys = newKeys;
		values = newValues;
		occupied = newOccupied;
		capacity = next;
		minimumCapacity = 0;
	}

	/** Insert or replace one value. */
	public function set(key:Int, value:V):Void {
		if (disposed)
			throw "Native integer map is already disposed";
		this.reserve(length + 1);
		var slot = hash(key) & (capacity - 1);
		while (occupiedAt(occupied, slot) != 0 && keyAt(keys, slot) != key)
			slot = (slot + 1) & (capacity - 1);
		if (occupiedAt(occupied, slot) == 0) {
			keys.offset(slot).store(cast key);
			occupied.offset(slot).store(cast 1);
			length++;
		}
		values.offset(slot).store(value);
	}

	/** Whether a key has an associated value. */
	public function exists(key:Int):Bool {
		if (disposed)
			throw "Native integer map is already disposed";
		if (capacity == 0)
			return false;
		var slot = hash(key) & (capacity - 1), probes = 0;
		while (probes < capacity && occupiedAt(occupied, slot) != 0) {
			if (keyAt(keys, slot) == key)
				return true;
			slot = (slot + 1) & (capacity - 1);
			probes++;
		}
		return false;
	}

	/** Read a value, throwing when the key is absent. */
	public function get(key:Int):V {
		if (disposed)
			throw "Native integer map is already disposed";
		if (capacity == 0)
			throw 'Native integer map has no value for key $key';
		var slot = hash(key) & (capacity - 1), probes = 0;
		while (probes < capacity && occupiedAt(occupied, slot) != 0) {
			if (keyAt(keys, slot) == key)
				return values.offset(slot).load();
			slot = (slot + 1) & (capacity - 1);
			probes++;
		}
		throw 'Native integer map has no value for key $key';
	}

	/** Remove every entry while retaining allocated storage. */
	public function clear():Void {
		if (disposed)
			throw "Native integer map is already disposed";
		for (index in 0...capacity)
			occupied.offset(index).store(cast 0);
		length = 0;
	}

	/** Release the backing arena. Repeated disposal is safe. */
	public function dispose():Void {
		if (disposed)
			return;
		disposed = true;
		keys = RawPtr.nullPtr();
		values = RawPtr.nullPtr();
		occupied = RawPtr.nullPtr();
		length = 0;
		capacity = 0;
		minimumCapacity = 0;
		arena.dispose();
	}

	static inline function hash(value:Int):Int {
		var result = value;
		result = (result ^ (result >>> 16)) * 0x45d9f3b;
		result = (result ^ (result >>> 16)) * 0x45d9f3b;
		return (result ^ (result >>> 16)) & 0x7FFFFFFF;
	}

	static inline function occupiedAt(pointer:RawPtr<UInt8>, index:Int):Int
		return cast pointer.offset(index).load();

	static inline function keyAt(pointer:RawPtr<Int32>, index:Int):Int
		return cast pointer.offset(index).load();
}
