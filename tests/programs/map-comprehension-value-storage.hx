struct MapFrame {
	public final number:Int;
	public function new(number:Int) this.number = number;
}
class MapReference {
	public final number:Int;
	public function new(number:Int) this.number = number;
}
function translate(value:MapFrame):MapFrame return new MapFrame(value.number + 1);
function main():Int {
	var strings:Map<String, MapFrame> = ["a" => new MapFrame(10), "b" => new MapFrame(20)];
	var mapped:Map<String, MapFrame> = [for (key => frame in strings) key => translate(frame)];
	var first = mapped.get("a") ?? throw "missing a";
	if (first.number != 11) return 1;
	var ints:Map<Int, MapFrame> = [1 => new MapFrame(30), 2 => new MapFrame(40)];
	var remapped:Map<Int, MapFrame> = [for (key => frame in ints) key + 1 => translate(frame)];
	var second = remapped.get(3) ?? throw "missing 3";
	if (second.number != 41) return 2;
	var nested:Map<String, Map<Int, MapFrame>> = [for (outer => frame in strings)
		outer => [for (inner => extra in ints) inner => new MapFrame(frame.number + extra.number)]];
	var inner = nested.get("b") ?? throw "missing b";
	var third = inner.get(2) ?? throw "missing 2";
	if (third.number != 60) return 3;
	var references:Map<String, MapReference> = ["a" => new MapReference(41)];
	var copied:Map<String, MapReference> = [for (key => value in references) key => new MapReference(value.number + 1)];
	var fourth = copied.get("a") ?? throw "missing reference";
	return fourth.number;
}
