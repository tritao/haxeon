package compiler.hl;

import compiler.core.InternalError;
import haxe.io.Bytes;

/**
 * LZ4 blocks, the encoding of a compressed HLB debug section (HlWriter.COMPRESSED). Compression is HashLink's native over the LZ4
 * the VM vendors, so the compiler writes the same bytes whichever compiler built it; decompression is plain Haxe, so every reader
 * decodes, the Haxe interpreter included.
 */
class HlLz4 {
	/** LZ4 HC's default level: within a percent of its best ratio, at several times the speed. */
	public static inline final HIGH = 9;

	/** LZ4's fast mode. */
	public static inline final FAST = 0;

	/**
	 * The block of `bytes` at `level` (FAST, or 1 to 12 for LZ4 HC), or null without the HashLink natives (under the Haxe
	 * interpreter, which builds the bootstrap seed): the caller then stores the payload as it is.
	 */
	public static function compress(bytes:Bytes, level:Int):Null<Bytes> {
		#if hl
		var capacity = bytes.length + Std.int(bytes.length / 255) + 16,
			block = Bytes.alloc(capacity),
			size = compressNative(bytes.getData(), bytes.length, block.getData(), capacity, level);
		if (size <= 0)
			throw new InternalError("LZ4 compression failed");
		return block.sub(0, size);
		#else
		return null;
		#end
	}

	/** The `size` bytes that the block at `bytes[position, position + length)` decodes to. */
	public static function decompress(bytes:Bytes, position:Int, length:Int, size:Int):Bytes {
		var output = Bytes.alloc(size), at = position, end = position + length, written = 0;
		if (position < 0 || length < 0 || end > bytes.length)
			throw new InternalError("Invalid LZ4 block");
		function byte():Int {
			if (at >= end)
				throw new InternalError("Truncated LZ4 block");
			return bytes.get(at++);
		}
		function extended(count:Int):Int {
			if (count == 15) {
				var next = 255;
				while (next == 255) {
					next = byte();
					count += next;
				}
			}
			return count;
		}
		while (true) {
			var token = byte(), literals = extended(token >>> 4);
			if (literals > end - at || literals > size - written)
				throw new InternalError("Invalid LZ4 literals");
			output.blit(written, bytes, at, literals);
			at += literals;
			written += literals;
			if (at == end)
				break;
			var offset = byte() | (byte() << 8), match = extended(token & 15) + 4;
			if (offset == 0 || offset > written || match > size - written)
				throw new InternalError("Invalid LZ4 match");
			if (offset >= match)
				output.blit(written, output, written - offset, match);
			else
				for (index in 0...match)
					output.set(written + index, output.get(written - offset + index));
			written += match;
		}
		if (written != size)
			throw new InternalError("LZ4 block does not decode to its size");
		return output;
	}

	#if hl
	@:hlNative("std", "bytes_lz4_compress")
	static function compressNative(source:hl.Bytes, length:Int, target:hl.Bytes, capacity:Int, level:Int):Int
		return 0;
	#end
}
