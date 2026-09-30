import Wasm32ValueRecords;

function main():Int {
	var output = Wasm32ValueRecords.write();
	if (output.get_x() != 17 || output.get_y() != 25)
		return 0;
	var value = new point();
	value.set_x(20);
	value.set_y(22);
	if (Wasm32ValueRecords.read(value) != 42 || Wasm32ValueRecords.sum(value) != 42)
		return 0;
	var updated = Wasm32ValueRecords.update(value);
	if (updated.get_x() != 21 || updated.get_y() != 24)
		return 0;
	var made = Wasm32ValueRecords.make(20);
	if (made.get_x() != 20 || made.get_y() != 22 || Wasm32ValueRecords.sum(made) != 42)
		return 0;
	var gappedValue = Wasm32ValueRecords.makeGapped(39);
	if (gappedValue.get_tag() != 3 || gappedValue.get_value() != 39 || Wasm32ValueRecords.sumGapped(gappedValue) != 42)
		return 0;
	// Records holding one scalar travel as that scalar, as clang's Wasm32 C ABI passes them.
	var id = new id64();
	id.set_value(haxe.Int64.make(1, 41));
	var next = Wasm32ValueRecords.nextId(id);
	if (next.get_value() != haxe.Int64.make(1, 42))
		return 0;
	var measure = new real();
	measure.set_value(84.5);
	if (Wasm32ValueRecords.half(measure).get_value() != 42.25)
		return 0;
	return 42;
}
