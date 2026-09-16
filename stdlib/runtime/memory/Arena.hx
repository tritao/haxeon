package runtime.memory;

import runtime.memory.RawPtr;

/** Stable, non-moving bump allocation for unmanaged, GC-free native values. */
class Arena {
	static inline final DEFAULT_BLOCK_SIZE = 65536;
	static inline final MIN_BLOCK_ALIGNMENT = 16;

	final defaultBlockSize:Int;
	final blocks:Array<ArenaBlock> = [];
	var blockCursor:Int = 0;

	public function new(?blockSize:Int = DEFAULT_BLOCK_SIZE) {
		if (blockSize <= 0)
			throw "Arena block size must be positive";
		defaultBlockSize = blockSize;
	}

	/** Allocate count contiguous native values with their C ABI alignment. */
	public function alloc<T>(?count:Int = 1):RawPtr<T> {
		if (count <= 0)
			throw "Arena allocation count must be positive";
		var elementSize = sizeof<T>(), alignment = alignof<T>(), blockAlignment = alignment < MIN_BLOCK_ALIGNMENT ? MIN_BLOCK_ALIGNMENT : alignment;
		if (elementSize <= 0 || alignment <= 0)
			throw "Arena allocation type must have a fixed native layout";
		if (count > Std.int(0x7FFFFFFF / elementSize))
			throw "Arena allocation size exceeds the supported range";
		var size = elementSize * count, block:ArenaBlock = null, offset = 0;
		if (size > 0x7FFFFFFF - (blockAlignment - 1))
			throw "Arena allocation size exceeds the supported range";
		while (blockCursor < blocks.length) {
			var candidate = blocks[blockCursor],
				candidateOffset = alignUp(candidate.used, alignment);
			if (candidate.baseAlignment >= alignment && candidate.baseAlignment % alignment == 0 && candidateOffset >= candidate.used
				&& candidateOffset <= candidate.capacity - size) {
				block = candidate;
				offset = candidateOffset;
				block.used = offset + size;
				break;
			}
			blockCursor++;
		}
		if (block == null) {
			var required = size + blockAlignment - 1,
				capacity = nextBlockSize(required),
				memory = ArenaNativeMemory.native_alloc(capacity, blockAlignment);
			block = new ArenaBlock(memory, capacity, blockAlignment);
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

	/** Capture the current allocation cursors for a recoverable append transaction. */
	public function checkpoint():ArenaCheckpoint
		return new ArenaCheckpoint(this, blocks.length, [for (block in blocks) block.used], blockCursor);

	/** Roll back allocations made after a checkpoint, releasing any new blocks. */
	public function rollback(checkpoint:ArenaCheckpoint):Void {
		if (checkpoint == null || checkpoint.arena != this)
			throw "Arena checkpoint belongs to another arena";
		if (checkpoint.blockCount < 0 || checkpoint.blockCount > blocks.length || checkpoint.used.length != checkpoint.blockCount)
			throw "Arena checkpoint is no longer valid";
		while (blocks.length > checkpoint.blockCount) {
			var block = blocks[blocks.length - 1];
			ArenaNativeMemory.native_free(block.memory);
			blocks.pop();
		}
		for (index in 0...checkpoint.blockCount)
			blocks[index].used = checkpoint.used[index];
		blockCursor = checkpoint.blockCursor;
	}

	/** Release every backing block. Repeated disposal is safe. */
	public function dispose():Void {
		for (block in blocks)
			ArenaNativeMemory.native_free(block.memory);
		blocks.resize(0);
		blockCursor = 0;
	}

	/** Check the address alignment of a live allocation. */
	public static inline function isAligned<T>(pointer:RawPtr<T>):Bool
		return ArenaNativeMemory.native_is_aligned(pointer.castTo(), alignof<T>());

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

/** Private HashLink boundary; Arena owns every block returned by these calls. */
@:hlNative("haxeon_runtime")
private class ArenaNativeMemory {
	public static function native_alloc(size:Int, alignment:Int):RawPtr<UInt8>
		return cast null;

	public static function native_free(pointer:RawPtr<UInt8>):Void {}

	public static function native_is_aligned(pointer:RawPtr<UInt8>, alignment:Int):Bool
		return false;
}

/** One backing allocation retained by an Arena until dispose. */
class ArenaBlock {
	public final memory:RawPtr<UInt8>;
	public final capacity:Int;
	public final baseAlignment:Int;
	public var used:Int = 0;

	public function new(memory:RawPtr<UInt8>, capacity:Int, baseAlignment:Int) {
		this.memory = memory;
		this.capacity = capacity;
		this.baseAlignment = baseAlignment;
	}
}

/** Allocation cursors retained by an Arena until a transaction commits or rolls back. */
class ArenaCheckpoint {
	final arena:Arena;
	final blockCount:Int;
	final used:Array<Int>;
	final blockCursor:Int;

	@:allow(runtime.memory.Arena)
	function new(arena:Arena, blockCount:Int, used:Array<Int>, blockCursor:Int) {
		this.arena = arena;
		this.blockCount = blockCount;
		this.used = used;
		this.blockCursor = blockCursor;
	}
}
