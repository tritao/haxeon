class Calls {
	static final box = new Box();
	static var called = false;

	static function adjust(value:Int):Int
		return value + 2;

	public static function invoke<T>(operation:Int->T):T
		return box.access(value -> operation(value));

	public static function answer():Int
		return invoke(value -> adjust(value));

	public static function run():Void
		invoke(value -> {
			called = value == 40;
		});

	public static function wasCalled():Bool
		return called;
}

class Box {
	public function new() {}

	public function access<T>(operation:Int->T):T
		return operation(40);
}

function answer():Int
	return Calls.answer();

function main():Int {
	Calls.run();
	return Calls.wasCalled() ? answer() : 0;
}
