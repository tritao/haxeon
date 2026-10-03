// Nullable primitives in every position the compiler types them: fields, parameters, results, array and map elements,
// closures, comparisons and dynamic conversions.
class Holder {
	public var count:Null<Int>;
	public var ratio:Null<Float>;
	public var flag:Null<Bool>;
	public var big:Null<haxe.Int64>;

	public function new() {}
}

function mix(hash:Int, value:Int):Int
	return hash * 31 + value;

function pick(use:Bool, value:Null<Int>):Null<Int>
	return use ? value : null;

function orZero(value:Null<Int>):Int
	return value == null ? 0 : value;

function orHalf(value:Null<Float>):Float
	return value == null ? 0.5 : value;

function describe(flag:Null<Bool>):Int
	return flag == null ? 2 : (flag ? 1 : 0);

function passThrough(value:Dynamic):Dynamic
	return value;

function sumAll(values:Array<Null<Int>>):Int {
	var total = 0;
	for (value in values)
		if (value != null)
			total += value;
	return total;
}

function checksum():Int {
	var h = 3;
	var holder = new Holder();
	h = mix(h, orZero(holder.count));
	h = mix(h, Std.int(orHalf(holder.ratio) * 100));
	h = mix(h, describe(holder.flag));
	h = mix(h, holder.big == null ? 7 : 8);
	holder.count = 41;
	holder.ratio = 2.5;
	holder.flag = false;
	holder.big = haxe.Int64.ofInt(123456);
	h = mix(h, orZero(holder.count) + 1);
	h = mix(h, Std.int(orHalf(holder.ratio) * 100));
	h = mix(h, describe(holder.flag));
	h = mix(h, holder.big == null ? 7 : haxe.Int64.toInt(holder.big));
	holder.count = null;
	h = mix(h, holder.count == null ? 1 : 0);

	var values:Array<Null<Int>> = [1, null, 3, null, 5];
	h = mix(h, sumAll(values));
	values[1] = 10;
	values.push(null);
	values.push(7);
	h = mix(h, sumAll(values));
	h = mix(h, values.length);

	var table = new Map<String, Null<Int>>();
	table.set("a", 4);
	table.set("b", null);
	h = mix(h, orZero(table.get("a")));
	h = mix(h, orZero(table.get("b")));
	h = mix(h, table.exists("b") ? 1 : 0);
	h = mix(h, table.get("missing") == null ? 1 : 0);

	var chosen = pick(true, 9);
	var dropped = pick(false, 9);
	h = mix(h, orZero(chosen));
	h = mix(h, dropped == null ? 1 : 0);
	h = mix(h, chosen == 9 ? 1 : 0);
	h = mix(h, chosen != 9 ? 1 : 0);

	var capture:Null<Int> = 12;
	var read = () -> capture == null ? -1 : capture;
	capture = 30;
	h = mix(h, read());
	capture = null;
	h = mix(h, read());

	var boxed:Dynamic = passThrough(21);
	var asNullable:Null<Int> = boxed;
	h = mix(h, orZero(asNullable));
	var boxedFloat:Dynamic = passThrough(6.5);
	var asNullableFloat:Null<Float> = boxedFloat;
	h = mix(h, Std.int(orHalf(asNullableFloat) * 10));
	var nothing:Dynamic = passThrough(null);
	var noInt:Null<Int> = nothing;
	h = mix(h, noInt == null ? 1 : 0);
	h = mix(h, Std.string(chosen).length);
	h = mix(h, Std.string(holder.ratio).length);
	return h;
}

function main():Int {
	if (checksum() != -1410354076)
		return 1;
	return 42;
}
