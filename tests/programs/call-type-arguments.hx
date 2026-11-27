// A call names its callee's own type arguments (docs/design/CALL_TYPE_ARGUMENTS.md): a function, a static or instance
// method, an enum method, a local function, an array method, a static extension and the wire codecs, where nothing else
// gives them. `<` stays a comparison where a call does not follow its type arguments.
import haxeon.wire.MessagePack;
import haxeon.wire.WireError;

using Lambda;

@:wire typedef Point = {
	@:id(1) var x:Int;
	@:id(2) var y:Int;
}

enum Problem {
	Wire(error:WireError);
}

class Box<T> {
	public final value:T;

	public function new(value:T)
		this.value = value;

	public function map<U>(f:T->U):Box<U>
		return new Box(f(value));

	public static function empty<U>():Array<U>
		return [];
}

function make<T>():Array<T>
	return [];

function apply<T>(f:T->Int):Int
	return 1;

function same<T>(value:T):T
	return value;

function count<T>(items:Array<T>):Int
	return items.length;

function inBody<T>(value:T):Int
	return make<T>().length + count<T>([value]);

function lessThan(a:Int, b:Int):Bool
	return a < b;

function both(first:Bool, second:Bool):Bool
	return first && second;

function decodePoint(bytes:haxe.io.Bytes):Result<Point, Problem> {
	var point = try MessagePack.decode<Point>(bytes).mapErr(Problem.Wire);
	return Ok(point);
}

function main():Int {
	var names = make<String>();
	names.push("a");
	if (names.length != 1 || Box.empty<Int>().length != 0)
		return 1;
	if (new Box(3).map<String>(n -> "#" + n).value != "#3")
		return 2;
	if (apply<Void>(() -> 7) != 1 || inBody<Float>(1.5) != 1)
		return 3;
	var grid = make<Array<Int>>(), callbacks = make<(Int) -> String>(), records = make<{name:String}>();
	grid.push([1]);
	callbacks.push(n -> "" + n);
	records.push({name: "r"});
	if (grid[0][0] != 1 || callbacks[0](2) != "2" || records[0].name != "r")
		return 4;
	function local<T>(value:T):Array<T>
		return [value];
	if (local<Int>(5)[0] != 5)
		return 5;
	var lengths = ["ab", "c"].map<Int>(text -> text.length);
	if (lengths[0] != 2 || lengths[1] != 1)
		return 6;
	// `Lambda.fold<A, B>`'s `A` is the receiver's element type, so only `B` is written.
	if ([1, 2].fold<String>((item, text) -> text + item, "") != "12")
		return 7;
	var result:Result<Int, String> = Ok(4);
	if (result.map<String>(n -> "v" + n).unwrapOr("none") != "v4")
		return 8;
	var bytes = MessagePack.encode<Point>({x: 3, y: 4});
	switch MessagePack.decode<Point>(bytes) {
		case Ok(point) if (point.x == 3 && point.y == 4):
		default:
			return 9;
	}
	switch decodePoint(haxe.io.Bytes.alloc(0)) {
		case Err(Wire(Truncated)):
		default:
			return 10;
	}
	// A written type is the call's, where the argument alone gives Int: a `Dynamic` stays Dynamic, a `Float` Float.
	var loose = same<Dynamic>(5), wide = same<Float>(5);
	loose = "five";
	wide = 0.5;
	if (loose != "five" || wide != 0.5)
		return 11;
	// Comparisons where no call follows the `>`, or where a parenthesis is not a function type's.
	var a = 1, b = 2, c = 3, d = 2;
	if (!lessThan(a, b) || !(a < b && c > d) || !both(a < (b), c > (d)))
		return 12;
	return 42;
}
