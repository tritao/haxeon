// A raw stack scan can misread a stale (frame, return-address) pair left behind
// by a sibling call that has already returned, as if it were still a live frame.
// `deepen` recurses well past what `probeStack`'s own shallow throw ever uses, so
// its old frames sit, unreleased but unoverwritten, above the current stack
// pointer by the time the second probe throws. A correct frame-pointer-chain walk
// reports exactly the live frames both times; a scanner is liable to report more
// of them on the second probe only, having picked up some of `deepen`'s leftover
// return addresses.
function fail():Void
	throw "boom";

function probeStack():Int {
	try {
		fail();
	} catch (e:Dynamic) {
		return haxe.CallStack.exceptionStack().length;
	}
}

function deepen(n:Int):Int
	return n <= 0 ? 0 : 1 + deepen(n - 1);

function main():Int {
	var before = probeStack();
	if (before <= 0)
		return 1;
	deepen(64);
	var after = probeStack();
	if (after != before)
		return 2;
	return 42;
}
