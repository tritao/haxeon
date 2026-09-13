import GcBytes;
import haxe.io.Bytes;

function main():Int {
	var payload = Bytes.ofString("gc bytes");
	if (GcBytes.inspect(payload) != 42)
		return 0;
	var backing = Bytes.ofString("!gc bytes?"),
		view = Bytes.view(backing, 1, 8);
	if (GcBytes.mutate(view) != 17
		|| backing.get(0) != 33
		|| backing.get(1) != 84
		|| backing.get(8) != 33
		|| backing.get(9) != 63)
		return 0;
	var output = GcBytes.read(7);
	if (output.status != 9 || output.data.length != 5 || output.data.get(0) != 104 || output.data.get(4) != 111)
		return 0;
	var fetched = GcBytes.fetch();
	if (fetched.length != 8 || fetched.get(0) != 70 || fetched.get(7) != 33)
		return 0;
	if (GcBytes.optional() != null)
		return 0;
	var owned = GcBytes.fetchOwned();
	if (owned.length != 4 || owned.get(0) != 79 || owned.get(3) != 33)
		return 0;
	var largePayload = Bytes.alloc(70000), index = 0;
	while (index < largePayload.length) {
		largePayload.set(index, index & 255);
		index = index + 1;
	}
	return GcBytes.inspect(largePayload);
}
