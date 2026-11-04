class ResizeItem {
	public final value:Int;
	public function new(value:Int) this.value = value;
}

function main():Int {
	var values = [40, 2];
	values.resize(4);
	if (values.length != 4 || values[2] != 0 || values[3] != 0)
		return 1;
	values.resize(2);
	var alias = values;
	values.resize(128);
	if (alias.length != 128 || values[0] != 40 || values[1] != 2 || values[127] != 0) return 2;
	values[127] = 9;
	values.resize(1);
	values.resize(128);
	if (values[1] != 0 || values[127] != 0) return 3;
	var floats:Array<Float> = [1.5];
	floats.resize(128);
	if (floats.length != 128 || floats[0] != 1.5 || floats[127] != 0.0) return 4;
	var flags:Array<Bool> = [true];
	flags.resize(128);
	if (flags.length != 128 || !flags[0] || flags[127]) return 5;
	var refs:Array<Null<ResizeItem>> = [new ResizeItem(7)];
	refs.resize(128);
	var first = refs[0];
	if (refs.length != 128 || first == null || first.value != 7 || refs[127] != null) return 6;
	refs[127] = new ResizeItem(9);
	refs.resize(1);
	refs.resize(128);
	if (refs[127] != null) return 7;
	return values[0] + 2;
}
