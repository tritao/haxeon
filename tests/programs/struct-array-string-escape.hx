struct StringPoint {
	public var x:Int;
	public function new(x:Int) this.x = x;
	public function toString():String return "point:" + x;
}

function main():Int {
	var points:Array<StringPoint> = [new StringPoint(42), new StringPoint(7)];
	var rendered = Std.string(points);
	if (rendered.length < 2 || rendered.charAt(0) != "[" || rendered.charAt(rendered.length - 1) != "]") return 1;
	#if !wasm
	if (rendered.indexOf("point:42") < 0 || rendered.indexOf("point:7") < 0) return 3;
	#end
	var nested:Array<Dynamic> = [points];
	var nestedRendered = Std.string(nested);
	if (nestedRendered.length < 4 || nestedRendered.charAt(0) != "[") return 2;
	#if !wasm
	if (nestedRendered.indexOf("point:42") < 0 || nestedRendered.indexOf("point:7") < 0) return 4;
	trace(Std.string(points));
	#end
	return 42;
}
