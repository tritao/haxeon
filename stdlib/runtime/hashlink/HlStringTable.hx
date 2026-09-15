package runtime.hashlink;

import runtime.memory.NativeString;
import runtime.memory.RawPtr;

/** Arena-owned indexed UTF-8 string table matching HashLink module pools. */
class HlStringTable {
	public final arena:HlTypeArena;
	public final pointers:RawPtr<RawPtr<UInt8>>;
	public final lengths:RawPtr<Int32>;
	public final ustrings:RawPtr<RawPtr<UInt16>>;
	public final count:Int;

	public function new(arena:HlTypeArena, values:Array<String>) {
		if (arena == null || values == null)
			throw "HashLink string table requires initialized storage and values";
		this.arena = arena;
		count = values.length;
		if (count == 0) {
			pointers = RawPtr.nullPtr();
			lengths = RawPtr.nullPtr();
			ustrings = RawPtr.nullPtr();
			return;
		}
		pointers = arena.allocNativePointerArray(count);
		lengths = arena.allocInt32Array(count);
		ustrings = arena.allocUInt16PointerArray(count);
		for (index in 0...count) {
			var value = values[index];
			var bytes = NativeString.utf8Bytes(value), pointer = arena.allocUInt8Array(bytes.length + 1);
			for (byteIndex in 0...bytes.length)
				pointer.offset(byteIndex).store(cast bytes[byteIndex]);
			pointer.offset(bytes.length).store(cast 0);
			pointers.offset(index).store(pointer);
			lengths.offset(index).store(cast bytes.length);
			ustrings.offset(index).store(RawPtr.nullPtr());
		}
	}

	public function pointer(index:Int):RawPtr<UInt8> {
		checkIndex(index);
		return pointers.offset(index).load();
	}

	public function lengthAt(index:Int):Int {
		checkIndex(index);
		return cast lengths.offset(index).load();
	}

	/** Compare one table entry with a Haxe string without creating a native wrapper. */
	public function equals(index:Int, value:String):Bool {
		checkIndex(index);
		var bytes = NativeString.utf8Bytes(value);
		if (bytes.length != lengthAt(index))
			return false;
		var entry = pointer(index);
		for (byteIndex in 0...bytes.length) {
			var actual:Int = cast entry.offset(byteIndex).load();
			if (actual != bytes[byteIndex])
				return false;
		}
		return true;
	}

	function checkIndex(index:Int):Void
		if (index < 0 || index >= count)
			throw 'HashLink string table index $index is outside 0...$count';
}
