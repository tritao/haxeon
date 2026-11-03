import haxe.Json;

struct JsonPoint {
	public var x:Int;
	public var label:String;
	public function new(x:Int, label:String) { this.x = x; this.label = label; }
}

function main():Int {
	var points:Array<JsonPoint> = [new JsonPoint(42, "first"), new JsonPoint(7, "second")];
	var view:Array<Dynamic> = cast points;
	var copy:JsonPoint = cast view[0];
	if (copy.x != 42 || copy.label != "first") return 1;
	copy.x = 0;
	if (points[0].x != 42) return 2;
	var iterator = view.iterator();
	if (!iterator.hasNext() || Reflect.field(iterator.next(), "x") != 42
		|| Reflect.field(iterator.next(), "label") != "second" || iterator.hasNext()) return 4;
	var json = Json.stringify(points);
	var decoded:Array<Dynamic> = cast Json.parse(json);
	if (decoded.length != 2 || Reflect.field(decoded[0], "x") != 42
		|| Reflect.field(decoded[1], "label") != "second") return 3;
	return 42;
}
