package runtime.memory;

/** Non-owning contiguous view over native arena elements. */
class NativeSlice<T> {
	public final pointer:RawPtr<T>;
	public final length:Int;

	public function new(pointer:RawPtr<T>, length:Int) {
		if (length < 0 || length > 0 && pointer.isNull())
			throw "Native slice requires a non-null pointer for non-empty storage";
		this.pointer = pointer;
		this.length = length;
	}

	public inline function get(index:Int):T {
		if (index < 0 || index >= length)
			throw 'Native slice index $index is outside 0...$length';
		return pointer.offset(index).load();
	}

	public inline function set(index:Int, value:T):Void {
		if (index < 0 || index >= length)
			throw 'Native slice index $index is outside 0...$length';
		pointer.offset(index).store(value);
	}

	public function sub(start:Int, count:Int):NativeSlice<T> {
		if (start < 0 || count < 0 || start > length - count)
			throw 'Native slice range $start...${start + count} is outside 0...$length';
		return new NativeSlice(pointer.byteOffset(start * sizeof<T>()), count);
	}

}
