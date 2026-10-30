import haxeon.Equality;
import haxeon.Structural;

@:structural class Point {
	public var x:Float;
	public var y:Float;

	public function new() {
		x = 0.0;
		y = 0.0;
	}
}

enum abstract Mode(Int) {
	var Plain = 1;
	var Bold = 2;
}

@:structural class Style {
	public var width:Int = 0;
	public var visible:Bool = true;
	public var mode:Mode = Plain;
	public var name:Null<String> = null;
	public var origin:Point;
	public var scale:Float = 1.0;

	public function new() {
		origin = new Point();
	}
}

/** Copy, equality, hash, masks and the change delta, all generated from Style's six fields. */
function main():Int {
	var a = new Style();
	a.width = 3;
	a.origin.x = 2.5;
	a.name = "n";
	var b = Structural.copy(a);
	if (b == a) return 1;
	if (!Equality.equals(a, b)) return 2;
	// Shallow: the nested instance is shared.
	if (b.origin != a.origin) return 3;
	if (Structural.hash(a) != Structural.hash(b)) return 4;
	b.width = 4;
	b.mode = Bold;
	var mask = Structural.changedMask(a, b);
	if (mask != (Structural.fieldBit(Style, "width") | Structural.fieldBit(Style, "mode"))) return 5;
	if (Equality.equals(a, b)) return 6;
	// A field changed outside the delta is left alone.
	var target = Structural.copy(a);
	target.visible = false;
	var applied = Structural.assignChanged(target, a, b);
	if (applied != mask || target.width != 4 || target.mode != Bold || target.visible) return 7;
	if (Structural.allFieldsMask(Style) != 63) return 8;
	var p = new Point(), q = new Point();
	q.y = 1.0;
	if (Equality.equals(p, q)) return 9;
	// Nested structural fields compare and hash by value, not identity.
	var c = Structural.copy(a);
	c.origin = new Point();
	c.origin.x = 2.5;
	if (!Equality.equals(a, c) || Structural.hash(a) != Structural.hash(c)) return 10;
	var nulled = Structural.copy(a);
	nulled.name = null;
	if (Equality.equals(a, nulled) || Structural.changedMask(a, nulled) != Structural.fieldBit(Style, "name")) return 11;
	return 42;
}
