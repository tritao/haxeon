function main():Int {
	var offset = 40;
	inline function add(value:Int):Int
		return offset + value;
	inline function twice(value:Int):Int {
		return 2 * value;
	}
	return add(twice(1));
}
