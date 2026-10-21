enum Access {
	Default;
	Get;
	Set;
	Never;
}

enum Node {
	Leaf(value:Int);
	Wrap(child:Null<Node>);
	Accessor(value:Null<Access>);
}

function storage(read:Null<Access>, write:Null<Access>):Bool {
	return switch [read, write] {
		case [Get, _], [_, Set], [Never, _], [_, Never]: false;
		default: true;
	};
}

function statement(values:Array<Null<Access>>):Int {
	switch values {
		case [Get, _]:
			return 1;
		case [_, Set]:
			return 2;
		case [null, null]:
			return 3;
		case [value, null] if (value == Default):
			return 4;
		default:
			return 5;
	}
}

function payload(value:Node):Int
	return switch value {
		case Wrap(Leaf(2)): 1;
		case Wrap(Wrap(Leaf(number))): number;
		case Wrap(null): 3;
		case Accessor(Get): 4;
		case Accessor(null): 5;
		default: 6;
	};

function tuplePayload(values:Array<Null<Node>>):Int
	return switch values {
		case [Wrap(Leaf(number)), _] if (number > 1): number;
		case [_, Leaf(number)]: number + 10;
		case [null, value]: value == null ? 30 : 31;
		default: 32;
	};

function main():Int {
	var values:Array<Null<Access>> = [null, Default, Get, Set, Never];
	for (read in values)
		for (write in values) {
			var expected = read != Get && read != Never && write != Set && write != Never;
			if (storage(read, write) != expected)
				return 1;
		}
	if (statement([null, null]) != 3 || statement([null, Set]) != 2 || statement([Get, null]) != 1 || statement([Default, null]) != 4
		|| statement([Default, Default]) != 5)
		return 2;
	if (payload(Wrap(null)) != 3
		|| payload(Wrap(Leaf(2))) != 1
		|| payload(Wrap(Wrap(Leaf(7)))) != 7
		|| payload(Wrap(Wrap(null))) != 6)
		return 3;
	if (payload(Accessor(null)) != 5 || payload(Accessor(Get)) != 4 || payload(Accessor(Default)) != 6)
		return 4;
	if (tuplePayload([null, null]) != 30
		|| tuplePayload([null, Leaf(2)]) != 12
		|| tuplePayload([Wrap(null), Leaf(3)]) != 13
		|| tuplePayload([Wrap(Leaf(4)), null]) != 4
		|| tuplePayload([Wrap(Leaf(0)), null]) != 32)
		return 5;
	return 42;
}
