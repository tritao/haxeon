// `==` and `!=` against a constructor without arguments ask which constructor a value is, as in Haxe, even for an enum whose
// other constructors have arguments and that does not conform to Equatable.
enum Direction {
	In;
	Out;
	InOut;
	OutArray(count:String);
}

function pick(index:Int):Direction
	return switch index {
		case 0: In;
		case 1: InOut;
		default: OutArray("n");
	};

function main():Int {
	var inOut = pick(1), array = pick(2);
	if (!(inOut == InOut) || inOut == In || InOut != inOut)
		return 1;
	if (array == InOut || !(array != Out) || Direction.In == array)
		return 2;
	var matches = 0;
	for (direction in [pick(0), pick(1), pick(2), pick(1)])
		if (direction == Direction.InOut)
			matches++;
	return matches == 2 ? 42 : 3;
}
