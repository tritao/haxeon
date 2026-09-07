class Callbacks {
	static var observed:Int = 0;

	static function record(value:Int):Int {
		observed = value + 2;
		return observed;
	}

	static function invoke(action:Int->Void, ?predicate:Int->Bool):Int {
		if (predicate != null && predicate(40))
			action(40);
		return observed;
	}

	public static function run():Int
		return invoke(value -> record(value), value -> value > 0);
}

function main():Int {
	return Callbacks.run();
}
