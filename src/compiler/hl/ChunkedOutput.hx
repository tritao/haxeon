package compiler.hl;

import haxe.io.Bytes;
import haxe.io.Output;

/**
 * An in-memory output that never reallocates what it has written. `haxe.io.BytesOutput` doubles its buffer and copies as it grows, so
 * a 100 MB module costs about three times that in allocation before `getBytes` copies it once more. This output keeps chunks, and
 * `getBytes` allocates the exact result once. `writeBytes` copies, as `Output` promises; `writeShared` keeps a reference instead, for
 * bytes the caller guarantees are never mutated again (an encoded function from the writer cache, a section payload).
 */
class ChunkedOutput extends Output {
	static inline final FIRST_CHUNK = 256;
	static inline final MAX_CHUNK = 262144;
	static inline final SHARED_MINIMUM = 4096;

	var segments:Array<Bytes> = [];
	var lengths:Array<Int> = [];
	var total = 0;
	static final NONE = Bytes.alloc(0);

	var chunk:Bytes = NONE;
	var used = 0;
	var nextChunk = FIRST_CHUNK;

	public function new() {
		bigEndian = false;
	}

	public var length(get, never):Int;

	function get_length():Int
		return total + used;

	function closeChunk():Void {
		if (used == 0)
			return;
		segments.push(chunk);
		lengths.push(used);
		total += used;
		chunk = NONE;
		used = 0;
	}

	/** The room for the next write, in a chunk allocated only when something is written to it. */
	inline function room():Void {
		if (used == chunk.length) {
			closeChunk();
			chunk = Bytes.alloc(nextChunk);
			if (nextChunk < MAX_CHUNK)
				nextChunk *= 2;
		}
	}

	override public function writeByte(c:Int):Void {
		room();
		chunk.set(used++, c);
	}

	override public function writeBytes(source:Bytes, position:Int, count:Int):Int {
		if (position < 0 || count < 0 || position + count > source.length)
			throw haxe.io.Error.OutsideBounds;
		var remaining = count, from = position;
		while (remaining > 0) {
			room();
			var take = chunk.length - used;
			if (take > remaining)
				take = remaining;
			chunk.blit(used, source, from, take);
			used += take;
			from += take;
			remaining -= take;
		}
		return count;
	}

	/** Appends `source` without copying it. The caller guarantees that its bytes are never changed afterwards. */
	public function writeShared(source:Bytes):Void {
		if (source.length < SHARED_MINIMUM) {
			writeBytes(source, 0, source.length);
			return;
		}
		closeChunk();
		segments.push(source);
		lengths.push(source.length);
		total += source.length;
	}

	/** Everything written, in one exactly sized buffer. */
	public function getBytes():Bytes {
		closeChunk();
		if (segments.length == 1 && lengths[0] == segments[0].length)
			return segments[0];
		var result = Bytes.alloc(total), offset = 0;
		for (index in 0...segments.length) {
			result.blit(offset, segments[index], 0, lengths[index]);
			offset += lengths[index];
		}
		return result;
	}
}
