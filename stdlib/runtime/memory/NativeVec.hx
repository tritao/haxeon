package runtime.memory;

/** Owning growable vector for fixed-layout native elements. */
class NativeVec<T> {
	public final arena:Arena;
	public var length(default, null):Int = 0;
	public var capacity(default, null):Int = 0;

	var pointer:RawPtr<T>;
	var minimumCapacity:Int;
	var disposed:Bool = false;

	public function new(?initialCapacity:Int = 8) {
		if (initialCapacity < 0)
			throw "Native vector capacity must be non-negative";
		arena = new Arena();
		pointer = RawPtr.nullPtr();
		minimumCapacity = initialCapacity;
		// Growth is deferred until the first push so the erased generic constructor
		// does not need to materialize T's native layout.
	}

	/** Address of the first element, or null when the vector is empty. */
	public inline function data():RawPtr<T>
		return pointer;

	public function reserve(required:Int):Void {
		if (disposed)
			throw "Native vector is already disposed";
		if (required < 0)
			throw "Native vector capacity must be non-negative";
		if (required <= capacity)
			return;
		var next = capacity == 0 ? 1 : capacity;
		while (next < required) {
			if (next > 0x3FFFFFFF)
				throw "Native vector capacity exceeds the supported range";
			next *= 2;
		}
		var grown:RawPtr<T> = arena.alloc(next);
		for (index in 0...length)
			grown.offset(index).store(pointer.offset(index).load());
		pointer = grown;
		capacity = next;
	}

	public function push(value:T):Void {
		var required = length + 1;
		if (required < minimumCapacity)
			required = minimumCapacity;
		minimumCapacity = 0;
		this.reserve(required);
		pointer.offset(length++).store(value);
	}

	public function get(index:Int):T {
		if (disposed)
			throw "Native vector is already disposed";
		if (index < 0 || index >= length)
			throw 'Native vector index $index is outside 0...$length';
		return pointer.offset(index).load();
	}

	public function set(index:Int, value:T):Void {
		if (disposed)
			throw "Native vector is already disposed";
		if (index < 0 || index >= length)
			throw 'Native vector index $index is outside 0...$length';
		pointer.offset(index).store(value);
	}

	public function pop():T {
		if (disposed)
			throw "Native vector is already disposed";
		if (length == 0)
			throw "Cannot pop an empty native vector";
		length--;
		return pointer.offset(length).load();
	}

	public inline function clear():Void {
		if (disposed)
			throw "Native vector is already disposed";
		length = 0;
	}

	/** Return a view that becomes invalid if this vector grows or is disposed. */
	public function slice():NativeSlice<T>
		return new NativeSlice(pointer, length);

	/** Release the backing arena. Repeated disposal is safe. */
	public function dispose():Void {
		if (disposed)
			return;
		disposed = true;
		pointer = RawPtr.nullPtr();
		length = 0;
		capacity = 0;
		minimumCapacity = 0;
		arena.dispose();
	}

}
