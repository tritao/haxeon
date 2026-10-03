function main():Int {
	var ints = [1, 2], floats = [1.5, 2.5];
	var intAlias = ints, floatAlias = floats;
	ints[ints.length] = 17;
	floats[floats.length] = 17.5;
	if (intAlias.length != 3 || intAlias[2] != 17 || floatAlias.length != 3 || floatAlias[2] != 17.5)
		return 1;
	ints[50] = 25;
	floats[50] = 24.5;
	if (ints.length != 51 || floats.length != 51 || intAlias[50] != 25 || floatAlias[50] != 24.5)
		return 2;
	if (intAlias[0] != 1 || floatAlias[0] != 1.5)
		return 3;
	var caught = 0;
	try {
		ints[-1] = 0;
	} catch (_:Dynamic) {
		caught++;
	}
	try {
		floats[-1] = 0.0;
	} catch (_:Dynamic) {
		caught++;
	}
	if (caught != 2 || ints.length != 51 || floats.length != 51)
		return 4;
	return 42;
}
