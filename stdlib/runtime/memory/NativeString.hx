package runtime.memory;

/** Owning null-terminated UTF-8 string backed by stable native storage. */
class NativeString {
	public final arena:Arena;
	public final length:Int;
	var pointer:RawPtr<UInt8>;
	var disposed:Bool = false;

	public function new(value:String) {
		if (value == null)
			throw "Native string value must be non-null";
		arena = new Arena();
		var bytes = utf8Bytes(value);
		length = bytes.length;
		pointer = arena.alloc(length + 1);
		for (index in 0...length)
			pointer.offset(index).store(cast bytes[index]);
		pointer.offset(length).store(cast 0);
	}

	/** Address of the null-terminated UTF-8 bytes, or null after disposal. */
	public inline function data():RawPtr<UInt8>
		return pointer;

	public inline function isDisposed():Bool
		return disposed;

	public function byteAt(index:Int):Int {
		if (disposed)
			throw "Native string is already disposed";
		if (index < 0 || index >= length)
			throw 'Native string byte index $index is outside 0...$length';
		return cast pointer.offset(index).load();
	}

	public function equals(other:NativeString):Bool {
		if (disposed || other == null || other.disposed || length != other.length)
			return false;
		for (index in 0...length)
			if (byteAt(index) != other.byteAt(index))
				return false;
		return true;
	}

	public function equalsUtf8(value:String):Bool {
		if (disposed || value == null)
			return false;
		var bytes = utf8Bytes(value);
		if (bytes.length != length)
			return false;
		for (index in 0...length)
			if (byteAt(index) != bytes[index])
				return false;
		return true;
	}

	/** Release the backing arena. Repeated disposal is safe. */
	public function dispose():Void {
		if (disposed)
			return;
		disposed = true;
		pointer = RawPtr.nullPtr();
		arena.dispose();
	}

	/** Return the UTF-8 byte length used by native string tables. */
	public static function utf8Length(value:String):Int
		return utf8Bytes(value).length;

	/** Encode a Haxe UTF-16 string as Unicode UTF-8 bytes. */
	public static function utf8Bytes(value:String):Array<Int> {
		if (value == null)
			throw "Native string value must be non-null";
		var result:Array<Int> = [], index = 0;
		while (index < value.length) {
			var code = value.charCodeAt(index++);
			if (code >= 0xD800 && code <= 0xDBFF && index < value.length) {
				var low = value.charCodeAt(index);
				if (low >= 0xDC00 && low <= 0xDFFF) {
					code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
					index++;
				}
			}
			if (code <= 0x7F)
				result.push(code);
			else if (code <= 0x7FF) {
				result.push(0xC0 | (code >> 6));
				result.push(0x80 | (code & 0x3F));
			} else if (code <= 0xFFFF) {
				result.push(0xE0 | (code >> 12));
				result.push(0x80 | ((code >> 6) & 0x3F));
				result.push(0x80 | (code & 0x3F));
			} else {
				result.push(0xF0 | (code >> 18));
				result.push(0x80 | ((code >> 12) & 0x3F));
				result.push(0x80 | ((code >> 6) & 0x3F));
				result.push(0x80 | (code & 0x3F));
			}
		}
		return result;
	}
}
