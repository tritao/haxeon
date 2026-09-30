@:value
class Span {
	public var start:Int;
	public var length:Int;

	public function new(start:Int, length:Int) {
		this.start = start;
		this.length = length;
	}
}

@:value
class Wide {
	public var a:Int;
	public var b:Float;
	public var flag:Bool;

	public function new(a:Int) {
		this.a = a;
	}
}

class Holder {
	public var span:Span;
	public var wide:Wide;

	public function new() {
		span = new Span(1, 2);
		wide = new Wide(3);
	}

	public function replace(start:Int):Void {
		span = new Span(start, 7);
	}
}

function main():Int {
	var failures = 0;
	var h = new Holder();
	if (h.span.start != 1 || h.span.length != 2 || h.wide.a != 3)
		failures += 1;
	h.replace(40);
	if (h.span.start != 40 || h.span.length != 7)
		failures += 2;
	// Fields the constructor does not write are reset to zero, not left as the slot's old contents.
	h.wide.b = 9.5;
	h.wide.flag = true;
	h.wide = new Wide(11);
	if (h.wide.a != 11 || h.wide.b != 0.0 || h.wide.flag)
		failures += 4;
	// A copy taken before the store keeps the old contents.
	var copy = h.span;
	h.span = new Span(5, 6);
	if (copy.start != 40 || copy.length != 7 || h.span.start != 5)
		failures += 8;
	// Values computed from the old contents are read before they are overwritten.
	h.span = new Span(h.span.length, h.span.start);
	if (h.span.start != 6 || h.span.length != 5)
		failures += 16;
	var total = 0;
	for (i in 0...5) {
		h.span = new Span(i, i + 1);
		total += h.span.length;
	}
	if (total != 15)
		failures += 32;
	var second = new Holder();
	second.span = h.span;
	h.span = new Span(0, 0);
	if (second.span.start != 4 || second.span.length != 5)
		failures += 64;
	return failures == 0 ? 42 : failures;
}
