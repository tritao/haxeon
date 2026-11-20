package runtime.memory;

import runtime.memory.RawPtr;

/**
 * Stable, non-moving bump allocation for unmanaged, GC-free native values (flat records only). Unchecked: `reset` and `dispose`
 * reuse or free the blocks whatever still points into them, and a dangling `RawPtr` is the caller's bug. `Arena` in the compiler
 * is the other kind: any object, released only when the runtime has checked that nothing points in (docs/design/ARENAS.md).
 */
class NativeArena {
	static inline final DEFAULT_BLOCK_SIZE = 65536;

	final defaultBlockSize:Int;
	final blocks:Array<NativeArenaBlock> = [];
	var blockCursor:Int = 0;

	public function new(?blockSize:Int = DEFAULT_BLOCK_SIZE) {
		if (blockSize <= 0)
			throw "NativeArena block size must be positive";
		defaultBlockSize = blockSize;
	}

	/** Allocate count contiguous native values with their C ABI alignment. */
	public function alloc<T>(?count:Int = 1):RawPtr<T> {
		if (count <= 0)
			throw "NativeArena allocation count must be positive";
		var elementSize = sizeof<T>(), alignment = alignof<T>();
		if (elementSize <= 0 || alignment <= 0)
			throw "NativeArena allocation type must have a fixed native layout";
		if (alignment > 16)
			throw "NativeArena currently supports native alignments up to 16 bytes";
		if (count > Std.int(0x7FFFFFFF / elementSize))
			throw "NativeArena allocation size exceeds the supported range";
		var size = elementSize * count, block:NativeArenaBlock = null, offset = 0;
		if (size > 0x7FFFFFFF - (alignment - 1))
			throw "NativeArena allocation size exceeds the supported range";
		while (blockCursor < blocks.length) {
			var candidate = blocks[blockCursor],
				candidateOffset = alignUp(candidate.used, alignment);
			if (candidateOffset >= candidate.used && candidateOffset <= candidate.capacity - size) {
				block = candidate;
				offset = candidateOffset;
				block.used = offset + size;
				break;
			}
			blockCursor++;
		}
		if (block == null) {
			var required = size + alignment - 1,
				capacity = nextBlockSize(required),
				memory = NativeArenaMemory.native_alloc(capacity);
			block = new NativeArenaBlock(memory, capacity);
			block.used = size;
			blocks.push(block);
			blockCursor = blocks.length - 1;
		}
		return block.memory.byteOffset(offset).castTo();
	}

	/** Reuse all acquired blocks from their beginnings. Existing pointers become invalid. */
	public function reset():Void {
		for (block in blocks)
			block.used = 0;
		blockCursor = 0;
	}

	/** Release every backing block. Repeated disposal is safe. */
	public function dispose():Void {
		for (block in blocks)
			NativeArenaMemory.native_free(block.memory);
		blocks.resize(0);
		blockCursor = 0;
	}

	function nextBlockSize(required:Int):Int {
		var capacity = defaultBlockSize;
		for (block in blocks)
			if (block.capacity > capacity && block.capacity <= 0x3FFFFFFF)
				capacity = block.capacity * 2;
		return required > capacity ? required : capacity;
	}

	static function alignUp(value:Int, alignment:Int):Int {
		var remainder = value % alignment;
		return remainder == 0 ? value : value + alignment - remainder;
	}
}

/** Private HashLink boundary; NativeArena owns every block returned by these calls. */
@:hlNative("haxeon_runtime")
private class NativeArenaMemory {
	public static function native_alloc(size:Int):RawPtr<UInt8>
		return cast null;

	public static function native_free(pointer:RawPtr<UInt8>):Void {}
}

/** One backing allocation retained by a NativeArena until dispose. */
class NativeArenaBlock {
	public final memory:RawPtr<UInt8>;
	public final capacity:Int;
	public var used:Int = 0;

	public function new(memory:RawPtr<UInt8>, capacity:Int) {
		this.memory = memory;
		this.capacity = capacity;
	}
}
