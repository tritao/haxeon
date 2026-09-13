import GcBytes;
import haxe.io.Bytes;

function main():Int {
	var payload = Bytes.ofString("gc bytes");
	if (GcBytes.inspect(payload) != 42)
		return 0;
	var largePayload = Bytes.alloc(70000), index = 0;
	while (index < largePayload.length) {
		largePayload.set(index, index & 255);
		index = index + 1;
	}
	return GcBytes.inspect(largePayload);
}
