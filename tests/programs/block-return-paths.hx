// Functions whose only return is inside a bare block, or in a switch ending in `case _:`, return the right values.
function wildcard(count:Int):String {
	switch count {
		case 1:
			return "one";
		case 2:
			return "two";
		case _:
			return "many";
	}
}

function named(count:Int):Int {
	switch count {
		case 0:
			return -1;
		case other:
			return other * 2;
	}
}

function blocks(count:Int):Int {
	var base = 10;
	{
		var scaled = count * 3;
		return scaled + base;
	}
}

function armBlocks(count:Int):Int {
	switch count {
		case 1:
			{
				return 100;
			}
		case _:
			{
				var shifted = count + 1;
				return shifted;
			}
	}
}

function main():Int {
	var checks = [
		wildcard(1) == "one",
		wildcard(2) == "two",
		wildcard(7) == "many",
		named(0) == -1,
		named(4) == 8,
		blocks(2) == 16,
		armBlocks(1) == 100,
		armBlocks(5) == 6
	];
	for (index in 0...checks.length)
		if (!checks[index])
			return index + 1;
	return 42;
}
