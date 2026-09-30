@:value
class Span {
	public var start:Int;
	public var length:Int;

	public function new(start:Int, length:Int) {
		this.start = start;
		this.length = length;
	}

	public function grow():Void {
		length = length + 1;
	}
}

@:value
class Pair {
	public var first:Span;
	public var second:Span;

	public function new(first:Span, second:Span) {
		this.first = first;
		this.second = second;
	}
}

// Every field is final, so an instance cannot be told apart from its copy.

@:value
class Frozen {
	public final a:Int;
	public final b:Int;

	public function new(a:Int, b:Int) {
		this.a = a;
		this.b = b;
	}
}

class Holder {
	public var span:Span;
	public var frozen:Frozen;

	public function new() {
		span = new Span(1, 2);
		frozen = new Frozen(3, 4);
	}

	public function current():Span {
		return span;
	}
}

function bump(span:Span):Int {
	span.start = span.start + 100;
	return span.start;
}

function reads(span:Span):Int {
	var total = 0;
	for (i in 0...3)
		total += span.start + span.length;
	return total;
}

// Writes to the holder's own span while reading its parameter: the parameter must be a copy taken before the call.
function readAfterOtherWrite(span:Span, holder:Holder):Int {
	holder.span.start = 500;
	return span.start;
}

function main():Int {
	var failures = 0;
	var h = new Holder();
	// A variable gets its own copy.
	var alias = h.span;
	h.span = new Span(5, 6);
	if (alias.start != 1 || alias.length != 2)
		failures += 1;
	alias.start = 9;
	if (h.span.start != 5)
		failures += 2;
	// Mutation through the place still reaches the holder.
	h.span.start = 7;
	h.span.grow();
	if (h.span.start != 7 || h.span.length != 7)
		failures += 4;
	// An argument is a copy: the callee's writes do not reach the caller.
	if (bump(h.span) != 107 || h.span.start != 7)
		failures += 8;
	// A returned field is a copy.
	var returned = h.current();
	returned.start = 50;
	if (h.span.start != 7)
		failures += 16;
	// Field to field.
	var other = new Holder();
	other.span = h.span;
	other.span.start = 60;
	if (h.span.start != 7 || other.span.start != 60)
		failures += 32;
	// An array element in and out.
	var list:Array<Span> = [];
	var source = new Span(2, 3);
	list.push(source);
	source.start = 99;
	var taken = list[0];
	taken.length = 40;
	if (list[0].start != 2 || list[0].length != 3)
		failures += 64;
	// Nested value classes copy deeply.
	var pair = new Pair(new Span(1, 1), new Span(2, 2));
	var duplicate = pair;
	duplicate.first.start = 77;
	if (pair.first.start != 1)
		failures += 128;
	// A fresh value is not copied again, and an immutable one is shared without anyone noticing.
	var fresh = new Span(3, 3);
	fresh.start = 4;
	var shared = h.frozen;
	if (fresh.start != 4 || shared.a != 3 || shared.b != 4)
		failures += 256;
	// A read-only callee sees the current contents.
	if (reads(h.span) != 3 * (7 + 7))
		failures += 512;
	// A callee that changes the source while it runs still sees the value from the moment of the call.
	h.span.start = 11;
	if (readAfterOtherWrite(h.span, h) != 11 || h.span.start != 500)
		failures += 1024;
	return failures == 0 ? 42 : failures;
}
