class MutatedBox {
	public var n:Int;

	public function new()
		n = 3;

	public function change():Void
		n = 11;
}

class CallKillCheck {
	public static function check():Int {
		var a = new MutatedBox();
		var before = a.n;
		var mutate = function():Void {
			a.n = 7;
		};
		mutate();
		var afterClosure = a.n;
		a.change();
		var afterMethod = a.n;
		return before + afterClosure + afterMethod + 21;
	}
}

function main():Int
	return CallKillCheck.check();
