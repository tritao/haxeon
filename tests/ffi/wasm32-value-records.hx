import Wasm32ValueRecords;

function main():Int {
	var output = Wasm32ValueRecords.write();
	if (output.x != 17 || output.y != 25)
		return 0;
	var value = new point();
	value.x = 20;
	value.y = 22;
	if (Wasm32ValueRecords.read(value) != 42 || Wasm32ValueRecords.sum(value) != 42)
		return 0;
	var updated = Wasm32ValueRecords.update(value);
	if (updated.x != 21 || updated.y != 24)
		return 0;
	var made = Wasm32ValueRecords.make(20);
	if (made.x != 20 || made.y != 22 || Wasm32ValueRecords.sum(made) != 42)
		return 0;
	var gappedValue = Wasm32ValueRecords.makeGapped(39);
	if (gappedValue.tag != 3 || gappedValue.value != 39 || Wasm32ValueRecords.sumGapped(gappedValue) != 42)
		return 0;
	// Records holding one scalar travel as that scalar, as clang's Wasm32 C ABI passes them.
	var id = new id64();
	id.value = haxe.Int64.make(1, 41);
	var next = Wasm32ValueRecords.nextId(id);
	if (next.value != haxe.Int64.make(1, 42))
		return 0;
	var measure = new real();
	measure.value = 84.5;
	if (Wasm32ValueRecords.half(measure).value != 42.25)
		return 0;
	// C floats cross as f32 values: the host sees 0.1 rounded to single precision.
	var scaled = Wasm32ValueRecords.scale(0.1, 4.0);
	if (Math.abs(scaled - 0.4) > 1e-6)
		return 0;
	return 42;
}
