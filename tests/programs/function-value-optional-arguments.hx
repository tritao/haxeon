// A local that holds a declared function can be called without the function's optional arguments, as the function
// itself can: the omitted ones take their defaults, or null when they have none.
class Util {
	public static function scale(value:Int, factor:Int = 10):Int
		return value * factor;
}

function frame(first:Int, second:Int, ?third:Int, fourth:Int = 5):Int
	return first + second + (third == null ? 0 : third) + fourth;

function main():Int {
	var direct = frame;
	var staticMethod = Util.scale;
	var results = [
		direct(1, 2),
		direct(1, 2, 3),
		direct(1, 2, 3, 4),
		staticMethod(2),
		staticMethod(2, 3)
	];
	var expected = [8, 11, 10, 20, 6];
	for (index in 0...results.length)
		if (results[index] != expected[index])
			return index + 1;
	return 42;
}
