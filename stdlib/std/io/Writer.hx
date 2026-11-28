package std.io;

import std.bytes.Bytes;

/**
 * A sink of bytes, written a part at a time: a file (`FileHandle.writer`), a child's input (`ChildInput`). `E` is what a
 * write fails with, the sink's own error (`FileError`, `ProcessError`). A subclass writes `writeRange`; `write` and
 * `writeText` are the same for every sink.
 */
abstract class Writer<E> {
	/** Writes all `length` bytes of `buffer` from `offset`, a range `write` has checked is inside it and is not empty. */
	abstract function writeRange(buffer:Bytes, offset:Int, length:Int):Result<Void, E>;

	/** Writes `length` bytes of `buffer` from `offset` (by default all of it), every one of them. A range outside the buffer throws. */
	public function write(buffer:Bytes, offset:Int = 0, length:Int = -1):Result<Void, E> {
		var count = length < 0 ? buffer.length - offset : length;
		Ranges.check(buffer, offset, count, "std.io.Writer");
		return count == 0 ? Ok() : writeRange(buffer, offset, count);
	}

	/** Writes `text` as UTF-8. */
	public function writeText(text:String):Result<Void, E>
		return write(Bytes.ofString(text));
}
