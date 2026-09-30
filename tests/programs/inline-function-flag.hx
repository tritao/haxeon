inline function twice(value:Int):Int {
	return value * 2;
}

class Math2 {
	public static inline function square(value:Int):Int {
		return value * value;
	}

	public inline function cube(value:Int):Int {
		return value * value * value;
	}

	public function new() {}
}

function main():Int {
	var math = new Math2();
	return twice(4) + Math2.square(3) + math.cube(2) + 17;
}
