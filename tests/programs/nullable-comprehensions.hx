class NullableItems {
	public function new() {}

	public function iterator():Null<Iterator<Int>>
		return [21].iterator();
}

function twice(values:Null<Array<Int>>):Array<Int>
	return [for (value in values) value * 2];

function main():Int {
	var array = twice([21]);
	var iterator = [for (value in new NullableItems()) value * 2];
	var gaps:Array<Int> = [];
	gaps[2] = 42;
	var flags:Array<Bool> = [];
	flags[2] = true;
	return array[0] == 42 && iterator[0] == 42 && gaps[0] == 0 && gaps[2] == 42 && !flags[0] && flags[2] ? 42 : 1;
}
