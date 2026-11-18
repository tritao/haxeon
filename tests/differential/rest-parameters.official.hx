// Rest parameters, as Haxe has them: `...values:T` is a `haxe.Rest<T>` holding the arguments from its position on, which a
// call passes one by one or spreads from an array (`f(...array)`), in functions, methods, constructors, generic functions and
// local functions.
using Main.Tools;

class Tools {
	public static function sumWith(base:Int,...values:Int):Int {
		var total = base;
		for (value in values)
			total += value;
		return total;
	}
}

class Counter {
	public var total = 0;

	public function new(...start:Int) {
		for (value in start)
			total += value;
	}

	public function add(label:String,...values:Int):String {
		for (value in values)
			total += value;
		return label + values.length;
	}
}

class Main {
	static function sum(...values:Int):Int {
		var total = 0;
		for (value in values)
			total += value;
		return total;
	}

	static function join<T>(separator:String,...items:T):String
		return [for (item in items) Std.string(item)].join(separator);

	static function describe(...values:String):String
		return values.length == 0 ? "none" : values[0] + "+" + (values.length - 1) + " " + values.toArray().join(",");

	static function copy(...values:Int):Array<Int>
		return values.toArray();

	static function main():Void {
		Sys.println(sum(1, 2, 3));
		Sys.println(sum());
		var numbers = [4, 5];
		Sys.println(sum(...numbers));
		Sys.println(join("-", "a", "b", "c"));
		Sys.println(join(",", 1, 2));
		Sys.println(describe());
		Sys.println(describe("x", "y", "z"));
		var counter = new Counter(10, 20);
		Sys.println(counter.add("n", 1, 2, 3) + " " + counter.total);
		Sys.println(counter.add("m") + " " + counter.total);
		var local = function(first:Int,...rest:String) return first + rest.length;
		Sys.println(local(1, "x", "y"));
		Sys.println(2.sumWith(3, 4));
		var copied = copy(...numbers);
		copied.push(6);
		Sys.println(numbers.length + " " + copied.length);
		var rest = haxe.Rest.of([7, 8]);
		Sys.println(rest.append(9).toString() + " " + rest.prepend(6).length + " " + rest.length);
		var total = 0;
		for (group in [[1, 2], [3]])
			total += sum(...group);
		Sys.println(total);
	}
}
