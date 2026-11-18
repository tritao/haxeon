// A function type written with a rest parameter, `(...Int)->Int`, is `haxe.Rest<Int> -> Int`: a function value of it packs
// the arguments of a call, or passes a spread array.
class Main {
	static function sum(...values:Int):Int {
		var total = 0;
		for (value in values)
			total += value;
		return total;
	}

	static function label(prefix:String,...values:Int):String
		return prefix + values.length;

	static function apply(f:(...Int) -> Int):Int
		return f(1, 2, 3);

	static function main():Void {
		var f:(...Int) -> Int = sum;
		Sys.println(f(1, 2) + " " + f() + " " + apply(sum));
		var named:(...values:Int) -> Int = sum;
		Sys.println(named(4, 5));
		var numbers = [7, 8];
		Sys.println(f(...numbers));
		var labelled:(String,...Int) -> String = label;
		Sys.println(labelled("n", 1, 2));
	}
}
