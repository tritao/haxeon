package profiler;

import haxe.io.Bytes;

/** LZ4 block decompression, as the runtime compresses each pushed data frame. */
class Lz4 {
	/** Decodes the block in `source` from `start` for `length` bytes into exactly `rawLength` bytes. */
	public static function decompressBlock(source:Bytes, start:Int, length:Int, rawLength:Int):Bytes {
		if (start < 0 || length < 0 || start + length > source.length || rawLength < 0)
			throw "Invalid LZ4 block bounds";
		var output = Bytes.alloc(rawLength), ip = start, end = start + length, op = 0;
		while (ip < end) {
			var token = source.get(ip++), literals = token >> 4;
			if (literals == 15) {
				var extra;
				do {
					if (ip >= end)
						throw "Truncated LZ4 literal length";
					extra = source.get(ip++);
					literals += extra;
				} while (extra == 255);
			}
			if (literals > end - ip || literals > rawLength - op)
				throw "LZ4 literals overrun the block";
			output.blit(op, source, ip, literals);
			ip += literals;
			op += literals;
			// The last sequence holds only literals.
			if (ip == end)
				break;
			if (end - ip < 2)
				throw "Truncated LZ4 match offset";
			var offset = source.get(ip) | (source.get(ip + 1) << 8);
			ip += 2;
			if (offset == 0 || offset > op)
				throw "Invalid LZ4 match offset";
			var matchLength = token & 15;
			if (matchLength == 15) {
				var extra;
				do {
					if (ip >= end)
						throw "Truncated LZ4 match length";
					extra = source.get(ip++);
					matchLength += extra;
				} while (extra == 255);
			}
			matchLength += 4;
			if (matchLength > rawLength - op)
				throw "LZ4 match overruns the output";
			var from = op - offset;
			if (offset >= matchLength)
				output.blit(op, output, from, matchLength);
			else
				// Overlapping copies repeat the pattern, so they go byte by byte.
				for (index in 0...matchLength)
					output.set(op + index, output.get(from + index));
			op += matchLength;
		}
		if (op != rawLength)
			throw 'LZ4 block decoded to $op bytes, expected $rawLength';
		return output;
	}
}
