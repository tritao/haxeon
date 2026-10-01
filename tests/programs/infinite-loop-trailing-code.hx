// Code after `while (true)` that only leaves by returning is accepted, as it is in Haxe.
function firstOver(limit:Int):Int {
	var i = 0;
	while (true) {
		i = i + 1;
		if (i > limit)
			return i;
	}
	return -1;
}

function noTrailing(limit:Int):Int {
	var i = 0;
	while (true) {
		i = i + 1;
		if (i > limit)
			return i;
	}
}

function trailingStatement(limit:Int):Int {
	var i = 0;
	while (true) {
		i = i + 1;
		if (i > limit)
			return i;
	}
	i = 100;
	return i;
}

function main():Int {
	return firstOver(3) + noTrailing(4) + trailingStatement(30) + 2;
}
