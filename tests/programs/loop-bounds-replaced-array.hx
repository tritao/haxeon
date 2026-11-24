// Loops whose bounds a proof could skip, where the array read is replaced through an element write or shrunk through an alias
// inside the loop: the first access past the end must still be checked, and throws (LANGUAGE_SUPPORT.md, out-of-range reads).
var reached = 0;

function replacedAfterCapture(arrs:Array<Array<Int>>):Int {
	var n = 0;
	for (i in 0...arrs[0].length) {
		arrs[0] = [7];
		n += arrs[0][i];
		reached = n;
	}
	return n;
}

function replacedBeforeAccess(arrs:Array<Array<Int>>):Int {
	var n = 0, i = 0;
	while (i < arrs[0].length) {
		arrs[0] = [7];
		n += arrs[0][i];
		reached = n;
		i++;
	}
	return n;
}

function shrunkThroughAlias(a:Array<Int>, alias:Array<Int>):Int {
	var n = 0;
	for (i in 0...a.length) {
		n += a[i];
		reached = n;
		alias.pop();
	}
	return n;
}

/** The sum `run` had reached when its out-of-range read threw, or -1 when none threw. */
function failsAt(run:() -> Int):Int {
	reached = 0;
	try {
		run();
	} catch (error:Dynamic) {
		return reached;
	}
	return -1;
}

function main():Int {
	var a = [1, 2, 3];
	if (failsAt(() -> replacedAfterCapture([[1, 2, 3]])) != 7 || replacedBeforeAccess([[1, 2, 3]]) != 7
		|| failsAt(() -> shrunkThroughAlias(a, a)) != 3)
		return 1;
	return 42;
}
