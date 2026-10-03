class DynamicBox {
	public var value:Dynamic;

	public function new()
		value = null;
}

class DynamicFieldCheck {
	public static function check():Int {
		var a = new DynamicBox();
		var i:Null<Int> = 7;
		a.value = i;
		var read:Dynamic = a.value;
		if (read != 7)
			return 1;
		var f:Null<Float> = 2.5;
		a.value = f;
		if (a.value != 2.5)
			return 2;
		i = null;
		a.value = i;
		return a.value == null ? 42 : 3;
	}
}

function main():Int
	return DynamicFieldCheck.check();
