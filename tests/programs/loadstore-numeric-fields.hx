class NumericBox {
	public var i:Null<Int>;
	public var f:Null<Float>;
	public var ordinary:Float;

	public function new() {
		i = null;
		f = null;
		ordinary = 0.0;
	}
}

class NumericFieldsCheck {
	public static function check():Int {
		var a = new NumericBox();
		if (a.i != null || a.f != null)
			return 1;
		a.i = 7;
		a.f = 2.5;
		a.ordinary = 0.0 / 0.0;
		var first = a.ordinary;
		var second = a.ordinary;
		if (first == first || second == second)
			return 2;
		if (a.i != 7 || a.f != 2.5)
			return 3;
		a.i = null;
		a.f = null;
		if (a.i != null || a.f != null)
			return 4;
		a.ordinary = 1.5;
		return a.ordinary + a.ordinary == 3.0 ? 42 : 5;
	}
}

function main():Int
	return NumericFieldsCheck.check();
