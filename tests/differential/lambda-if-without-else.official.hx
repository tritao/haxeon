// A lambda whose body is an `if` without an `else` is a Void function, as a loop body is; with an `else` it returns the value
// of the branch taken. Nested branches, a braced then branch and an `if` inside the condition's parentheses keep their own.
class Main {
	static var seen:Array<String> = [];

	static function each(values:Array<Int>, f:Int->Void):Void
		for (value in values)
			f(value);

	static function map(values:Array<Int>, f:Int->String):Array<String>
		return [for (value in values) f(value)];

	static function main():Void {
		each([1, 2, 3], x -> if (x > 1) seen.push("big " + x));
		each([4, 5], x -> if (x == 4) {
			seen.push("four");
			seen.push("again");
		});
		each([6, 7], x -> if ((if (x > 6) true else false)) seen.push("seven"));
		each([8, 9], x -> if (x > 7) if (x == 9) seen.push("nine") else seen.push("eight"));
		Sys.println(seen.join(","));
		Sys.println(map([1, 2], x -> if (x == 1) "one" else "two").join(","));
		Sys.println(map([3], x -> if (x == 3) {
			"three";
		} else {
			"other";
		}).join(","));
	}
}
