package std.io;

import std.bytes.Bytes;

/** The check `read` and `write` make of the range they are given. */
internal class Ranges {
	/** Throws unless `length` bytes from `offset` are inside `buffer`: a misuse, which `owner` names. */
	public static function check(buffer:Null<Bytes>, offset:Int, length:Int,
			owner:String):Void // `offset > length - count` rather than `offset + count > length`, which overflows for a large count.
		if (buffer == null || offset < 0 || length < 0 || offset > buffer.length - length)
			throw new haxe.Exception('$owner: the range is outside the buffer');
}
