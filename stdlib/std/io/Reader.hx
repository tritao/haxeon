package std.io;

import std.bytes.Bytes;
import std.bytes.BytesBuffer;

/**
 * A source of bytes, read a part at a time: a file (`FileHandle.reader`), a child's output (`ChildOutput`). `E` is what a
 * read fails with, the source's own error (`FileError`, `ProcessError`). A subclass writes `readRange`; `read`, `readAll`
 * and `readText` are the same for every source.
 */
abstract class Reader<E> {
	/**
	 * Reads up to `length` bytes into `buffer` from `offset`, a range `read` has checked is inside it and is not empty: how
	 * many it read, which may be fewer than asked, and 0 at the source's end.
	 */
	abstract function readRange(buffer:Bytes, offset:Int, length:Int):Result<Int, E>;

	/**
	 * Reads up to `length` bytes into `buffer` from `offset` (by default to its end): how many it read, which may be fewer
	 * than asked, and 0 at the source's end. A range outside the buffer throws.
	 */
	public function read(buffer:Bytes, offset:Int = 0, length:Int = -1):Result<Int, E> {
		var count = length < 0 ? buffer.length - offset : length;
		Ranges.check(buffer, offset, count, "std.io.Reader");
		return count == 0 ? Ok(0) : readRange(buffer, offset, count);
	}

	/** Reads to the source's end, and answers all of it. */
	public function readAll():Result<Bytes, E> {
		var chunk = Bytes.alloc(16384), all = new BytesBuffer();
		while (true) {
			var got = try readRange(chunk, 0, chunk.length);
			if (got == 0)
				return Ok(all.getBytes());
			all.addBytes(chunk, 0, got);
		}
	}

	/** Reads to the source's end, and answers it as UTF-8 text. */
	public function readText():Result<String, E> {
		var bytes = try readAll();
		return Ok(bytes.toString());
	}
}
