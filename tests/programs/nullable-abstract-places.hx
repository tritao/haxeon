struct PlacePayload {
	public var x:Int;
	public function new(x:Int) this.x = x;
}
abstract PlaceWrap(PlacePayload) {
	public function new(x:Int) this = new PlacePayload(x);
	public function read():Int return this.x;
}
class PlaceHolder {
	public var field:Null<PlaceWrap>;
	public function new(value:Null<PlaceWrap>) field = value;
}
function main():Int {
	var holder = new PlaceHolder(null);
	try {
		var missing:PlaceWrap = cast holder.field;
		return missing.read();
	} catch (_:Dynamic) {}
	holder.field = new PlaceWrap(42);
	var field:PlaceWrap = cast holder.field;
	if (field.read() != 42) return 1;
	var array:Array<Null<PlaceWrap>>= [null, new PlaceWrap(42)];
	try {
		var missing:PlaceWrap = cast array[0];
		return missing.read();
	} catch (_:Dynamic) {}
	var item:PlaceWrap = cast array[1];
	if (item.read() != 42) return 2;
	var captured:Null<PlaceWrap>= null;
	var read = function():Int {
		var value:PlaceWrap = cast captured;
		return value.read();
	};
	try {
		return read();
	} catch (_:Dynamic) {}
	captured = new PlaceWrap(42);
	return read();
}
