class HandlerBox {
	public var n:Int;

	public function new()
		n = 3;
}

class HandlerCheck {
	public static function check():Int {
		var a = new HandlerBox();
		var initial = a.n;
		try {
			a.n = 39;
			throw "boom";
		} catch (error:Dynamic) {
			return initial + a.n;
		}
	}
}

function main():Int
	return HandlerCheck.check();
