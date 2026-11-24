// `if (c) {} else f()` as the last thing in a switch branch or a block is a statement `if` with an empty block. The
// parser tries an expression first at those places; there `{}` must not become an empty object (a conditional that
// builds an object nobody wants). Where only a value can stand, `{}` stays an empty object.
function bump(hits:Array<Int>):Void
	hits[0]++;

function count(hits:Array<Int>):Int {
	hits[0] += 10;
	return hits[0];
}

function each(action:Int->Void):Void
	action(1);

function inSwitch(n:Int, skip:Bool, other:Bool, hits:Array<Int>):Void {
	switch n {
		case 0:
			if (skip) {} else bump(hits);
		case 1:
			if (skip) {} else count(hits);
		case 2:
			if (skip) count(hits) else {}
		case 3:
			if (skip) {} else if (other) {} else count(hits);
		default:
	}
}

function inBodies(skip:Bool, hits:Array<Int>):Void {
	var block = () -> {
		bump(hits);
		if (skip) {} else count(hits);
	};
	block();
	each(item -> if (skip) {} else count(hits));
}

function main():Int {
	var hits = [0];
	inSwitch(0, false, false, hits);
	inSwitch(0, true, false, hits);
	if (hits[0] != 1)
		return 1;
	inSwitch(1, false, false, hits);
	inSwitch(1, true, false, hits);
	if (hits[0] != 11)
		return 2;
	inSwitch(2, true, false, hits);
	inSwitch(2, false, false, hits);
	if (hits[0] != 21)
		return 3;
	inSwitch(3, true, false, hits);
	inSwitch(3, false, true, hits);
	if (hits[0] != 21)
		return 4;
	inSwitch(3, false, false, hits);
	inBodies(true, hits);
	if (hits[0] != 32)
		return 5;
	// `{}` is still an empty object where a value is meant.
	var empty:Dynamic = hits[0] > 100 ? null : {};
	var chosen:Dynamic = if (hits[0] > 100) {} else {extra: 10};
	if (empty == null)
		return 6;
	return hits[0] + Std.int(Reflect.field(chosen, "extra"));
}
