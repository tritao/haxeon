class StringFieldProbe {
	public var identity:Int;
	public var width:Int;

	public function new() {
		identity = 7;
		width = 12;
	}
}

function main():Int {
	var value = new StringFieldProbe();
	var text = 'image(${value.identity},${value.width}x${value.width})';
	var dynamic:Dynamic = 1.5;
	return text == "image(7,12x12)" && Std.string(value) == "Object" && Std.string(dynamic) == "1.5" ? 42 : 0;
}
