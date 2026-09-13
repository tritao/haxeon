import GcBytes;
import haxe.io.Bytes;

function main():Int {
	var malformed:GcBytes.gc_fixture_point = cast Bytes.alloc(4);
	GcBytes.shiftPoint(malformed);
	return 42;
}
