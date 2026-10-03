class ForwardBox {
	public var n:Int;
	public var other:Int;

	public function new() {
		n = 3;
		other = 0;
	}
}

class ObjectAliasCheck {
	static function observe(a:ForwardBox, b:ForwardBox):Int {
		var before = a.n;
		b.n = 39;
		b.other = 2;
		return before + a.n;
	}

	public static function check():Int {
		var a = new ForwardBox();
		return observe(a, a);
	}
}

function main():Int
	return ObjectAliasCheck.check();
