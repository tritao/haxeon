// A loop with an empty body, `while (next() & 0x80 != 0) {}`, is one block that ends with a conditional jump back to its own
// start. Values from before the loop (`this`, an argument) stay live across the call in it, so the HashLink JIT must see that
// block as a loop: it once took only a later block as a back edge, kept them in registers the call overwrites, and the loop
// read a clobbered `this` on its second pass.
class VarIntReader {
	public var position = 0;

	public function new() {}

	public function skip(bytes:Array<Int>):Void {
		while (byteAt(bytes, position++) & 0x80 != 0) {}
	}

	@:noInline static function byteAt(bytes:Array<Int>, index:Int):Int {
		if (index >= bytes.length)
			throw "read past the end";
		return bytes[index];
	}
}

@:noInline function spin(step:Int, limit:Int):Int {
	while (bump(step) < limit) {}
	return total;
}

var total = 0;

@:noInline function bump(step:Int):Int {
	total += step;
	return total;
}

function main():Int {
	var reader = new VarIntReader();
	reader.skip([0x80, 0x81, 0x01, 0x05, 0x80, 0x00]);
	if (reader.position != 3)
		return 100 + reader.position;
	reader.skip([0, 0, 0, 0x80, 0x80, 0x7f]);
	if (reader.position != 6)
		return 110 + reader.position;
	if (spin(3, 10) != 12)
		return 120;
	return 42;
}
