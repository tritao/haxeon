// What a branch inside an expression assigns holds after the expression, as after a statement: a local known to be null
// before a conditional, a logical operator or a switch expression, and assigned in one of its branches, is no longer known
// to be null after it.
enum Shape {
	Dot;
	Box(n:Int);
}

function probe(n:Int):Null<String>
	return n > 2 ? 'hit $n' : null;

function conditional(go:Bool):Int {
	var found = probe(0);
	if (found != null)
		return 0;
	var assigned = go ? (found = probe(5)) != null : false;
	return found != null && assigned ? 1 : 0;
}

function ifExpression(go:Bool):Int {
	var found = probe(0);
	if (found != null)
		return 0;
	var k = if (go) {
		found = probe(5);
		1;
	} else 0;
	return found != null ? k : 0;
}

function logicalAnd(go:Bool):Int {
	var found = probe(0);
	if (found != null)
		return 0;
	if (go && (found = probe(5)) != null) {}
	return found != null ? 1 : 0;
}

function logicalOr(stop:Bool):Int {
	var found = probe(0);
	if (found != null)
		return 0;
	if (stop || (found = probe(5)) == null) {}
	return found != null ? 1 : 0;
}

function switchExpression(shape:Shape):Int {
	var found = probe(0);
	if (found != null)
		return 0;
	var k = switch shape {
		case Box(n):
			found = probe(n);
			1;
		case Dot: 0;
	}
	return found != null ? k : 0;
}

// A branch that cannot continue does not join: after it, the other branch's narrowing holds.
function neverBranch(value:Null<String>):Int {
	var length = value == null ? throw "missing" : value.length;
	return length;
}

function main():Int {
	var go = Std.random(1) == 0;
	return conditional(go) + ifExpression(go) + logicalAnd(go) + logicalOr(!go) + switchExpression(Box(5)) * 10
		+ neverBranch("abcdefghijklmnopqrstuvwxyz0123") == 44 ? 42 : 1;
}
