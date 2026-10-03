class LoopBox {
	public var n:Int;

	public function new()
		n = 0;
}

class LoopCheck {
	public static function check():Int {
		var a = new LoopBox();
		var total = 0;
		for (i in 0...7) {
			total += a.n;
			a.n = a.n + 1;
		}
		return total + a.n + 14;
	}
}

function main():Int
	return LoopCheck.check();
