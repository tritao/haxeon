@:value
class Span {
	public var start:Int;
	public var length:Int;

	public function new(start:Int, length:Int) {
		this.start = start;
		this.length = length;
	}

	public function end():Int {
		return start + length;
	}

	public function shifted(by:Int):Int {
		return end() + by;
	}
}

class Holder {
	public var span:Span;

	public function new(span:Span) {
		this.span = span;
	}
}

function main():Int {
	var span = new Span(3, 4);
	var holder = new Holder(new Span(10, 5));
	var failures = 0;
	if (span.end() != 7)
		failures += 1;
	if (span.shifted(3) != 10)
		failures += 2;
	if (holder.span.end() != 15)
		failures += 4;
	return failures == 0 ? 42 : failures;
}
