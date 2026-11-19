package compiler.query;

/**
 * Builds a query value's digest: two independent 32-bit hashes of the parts fed in, in order. Values whose digests are
 * equal are taken to be equal; check mode compares whole values. Feeding allocates nothing.
 */
class Digest {
	public var first(default, null):Int;
	public var second(default, null):Int;

	public function new() {
		reset();
	}

	public function reset():Void {
		first = cast 0x811C9DC5;
		second = cast 0x2545F491;
	}

	public function int(value:Int):Digest
		return byte(value & 0xFF).byte((value >>> 8) & 0xFF).byte((value >>> 16) & 0xFF).byte(value >>> 24);

	public function bool(value:Bool):Digest
		return byte(value ? 1 : 0);

	/** A string, with its length first, so that consecutive strings cannot run into each other. */
	public function string(value:String):Digest {
		int(value.length);
		for (index in 0...value.length) {
			var code = StringTools.fastCodeAt(value, index);
			byte(code & 0xFF);
			byte(code >>> 8);
		}
		return this;
	}

	/** Bytes, with their length first. */
	public function bytes(value:haxe.io.Bytes):Digest {
		int(value.length);
		for (index in 0...value.length)
			byte(value.get(index));
		return this;
	}

	/** Another digest, such as a part's or a dependency's. */
	public function digest(first:Int, second:Int):Digest
		return int(first).int(second);

	function byte(code:Int):Digest {
		first = (first ^ code) * 16777619;
		second = (((second << 5) | (second >>> 27)) ^ code) * (cast 0x85EBCA6B:Int);
		return this;
	}
}
