struct NullDispatchValue {
	public var number:Int;
	public function new(number:Int) this.number = number;
}

class NullDispatchBox<T> {
	public function new() {}
	public function get():T {
		NullDispatchProbe.entered++;
		throw "the receiver was not checked";
	}
}

class NullDispatchProbe { public static var entered:Int = 0; }

function missingBox():NullDispatchBox<NullDispatchValue> {
	var value:Dynamic = null;
	return cast value;
}

function main():Int {
	try {
		var box = missingBox();
		var value:NullDispatchValue = box.get();
		return value.number;
	} catch (error:Dynamic) {
		return NullDispatchProbe.entered == 0 ? 42 : 1;
	}
}
