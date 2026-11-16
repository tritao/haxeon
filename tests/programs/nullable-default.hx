// A nullable Int, Float or Bool reads as the plain type, null giving the Haxe default (0, 0.0, false), evaluated once.
function take(x:Int):Int
	return x;

function give(m:Map<String, Int>):Int
	return m.get("missing");

function main():Int {
	var m = new Map<String, Int>();
	m.set("a", 40);
	var a:Int = m.get("a");
	var missing:Int = m.get("b");
	var n:Null<Int> = null;
	var f:Float = n;
	var nf:Null<Float> = null;
	var g:Float = nf;
	var nb:Null<Bool> = null;
	var b:Bool = nb;
	var present:Null<Int> = 2;
	var calls = 0;
	function once():Null<Int> {
		calls++;
		return 1;
	}
	var c:Int = once();
	return a + missing + take(present) + give(m) + Std.int(f + g) + (b ? 100 : 0) + c - calls + operators();
}

/** Operators read a nullable number or Bool as the plain value, null as its default, as Haxe does; == still sees null. */
function operators():Int {
	var n:Null<Int> = null, p:Null<Int> = 3, f:Null<Float> = null, b:Null<Bool> = null, t = 5;
	t += n;
	var checks:Array<Bool> = [
		t == 5,
		n + 1 == 1,
		f * 2 == 0,
		p + 1 == 4,
		p < 4,
		n < 1,
		-p == -3,
		(p & 1) == 1,
		p % 2 == 1,
		!b,
		(b ? 1 : 2) == 2,
		n == null,
		p != null
	];
	// ++ and -- treat a nullable number as the number, null as 0, as statements and as expressions.
	var counter:Null<Int> = null;
	counter++;
	var before = counter++;
	var scaled:Null<Float> = 2.5;
	scaled--;
	var holder = new Holder();
	holder.count++;
	Holder.total--;
	// Joining a nullable with a plain number keeps the nullable: the default applies only where a plain value is required.
	var counts = ["a" => 1];
	var joined = n == null ? counts.get("missing") : 5;
	var listed = [counts.get("missing"), 3];
	var measured:Null<Float> = 42.7;
	checks = checks.concat([
		counter == 2,
		before == 1,
		scaled == 1.5,
		holder.count == 1,
		Holder.total == -1,
		Std.int(measured) == 42,
		~n == -1,
		joined == null,
		listed[0] == null
	]);
	var ok = 0;
	if (b)
		return -100;
	while (b)
		return -100;
	for (check in checks)
		if (check)
			ok++;
	return ok == checks.length ? 0 : -1;
}

class Holder {
	public static var total:Null<Int> = null;

	public var count:Null<Int> = null;

	public function new() {}
}
