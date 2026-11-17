// An Int flowing into a local whose type is already Float is widened, as in Haxe; the local's type stays Float.
class Main {
	static function average(values:Array<Float>):Float {
		var sum = 0.0;
		for (value in values)
			sum += value;
		return sum / values.length;
	}

	static function main():Void {
		var values = [];
		var ignored = average(values.length == 0 ? [1.5] : values);
		values.push(1);
		values.push(2.5);
		values.push(4);
		Sys.println(average(values) + " " + ignored);

		var total;
		total = 0.25;
		total = 3;
		total += 1;
		Sys.println(total / 8);

		var scale = null;
		scale = 0.5;
		scale = 2;
		Sys.println(scale * 3);

		var weights = new Map();
		weights.set("a", 0.5);
		weights.set("b", 2);
		Sys.println(weights.get("a") + weights.get("b"));
	}
}
