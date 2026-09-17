package runtime.hashlink;

import runtime.memory.RawPtr;

/** Stable module-local function dispatch and signature slots. */
class HlFunctionTable {
	public final arena:HlTypeArena;
	final functions:RawPtr<RawPtr<UInt8>>;
	final types:RawPtr<RawPtr<HlType>>;
	final count:Int;

	public function new(arena:HlTypeArena, functionPointers:Array<RawPtr<UInt8>>, functionTypes:Array<RawPtr<HlType>>) {
		if (arena == null || functionPointers == null || functionTypes == null || functionPointers.length != functionTypes.length)
			throw "HashLink function and type tables must have equal lengths";
		this.arena = arena;
		count = functionPointers.length;
		functions = count == 0 ? RawPtr.nullPtr() : arena.allocNativePointerArray(count);
		types = count == 0 ? RawPtr.nullPtr() : arena.allocTypePointerArray(count);
		for (index in 0...count) {
			if (functionTypes[index].isNull())
				throw 'HashLink function table type at slot $index cannot be null';
			if (!arena.ownsType(functionTypes[index]))
				throw 'HashLink function table type at slot $index must belong to its arena';
			functions.offset(index).store(functionPointers[index]);
			types.offset(index).store(functionTypes[index]);
		}
	}

	public inline function length():Int
		return count;

	/** Address of the native function-pointer table, or null when empty. */
	public inline function functionPointer():RawPtr<RawPtr<UInt8>>
		return functions;

	/** Address of the native function-type table, or null when empty. */
	public inline function typePointer():RawPtr<RawPtr<HlType>>
		return types;

	public function functionAt(index:Int):RawPtr<UInt8> {
		checkIndex(index);
		return functions.offset(index).load();
	}

	public function typeAt(index:Int):RawPtr<HlType> {
		checkIndex(index);
		return types.offset(index).load();
	}

	/** Replace a dispatch address without changing the table's stable shape. */
	public function setFunction(index:Int, pointer:RawPtr<UInt8>):Void {
		checkIndex(index);
		functions.offset(index).store(pointer);
	}

	/** Replace a signature slot without moving the table. */
	public function setType(index:Int, type:RawPtr<HlType>):Void {
		checkIndex(index);
		if (type.isNull() || !arena.ownsType(type))
			throw 'HashLink function table type at slot $index must belong to its arena';
		types.offset(index).store(type);
	}

	function checkIndex(index:Int):Void
		if (index < 0 || index >= count)
			throw 'HashLink function table index $index is outside 0...$count';
}
