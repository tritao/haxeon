// `==` and `!=` against a constructor without arguments ask which constructor a value is, as in Haxe, even for an enum whose
// other constructors have arguments and that does not conform to Equatable; a null value is none of them.
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
	if (matches != 2)
		return 3;
	var maybe:Null<Direction> = null;
	if (maybe == In || !(maybe != Out))
		return 4;
	maybe = pick(1);
	if (!(maybe == InOut) || maybe == In)
		return 5;
	var calls = 0;
	function counted():Null<Direction> {
		calls++;
		return calls > 5 ? null : pick(2);
	}
	if (counted() == InOut || calls != 1)
		return 6;
	return 42;
}
