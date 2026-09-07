enum Access {
	Default;
	Never;
	Get;
	Set;
}

enum OptionalValue {
	Found(value:Int);
	Missing;
}

function read(value:Null<OptionalValue>):Int
	return switch value {
		case OptionalValue.Found(result): result;
		case OptionalValue.Missing: 1;
		case null: 2;
	};

function isPhysical(access:Null<Access>):Bool
	return switch access {
		case Get, Set, Never: false;
		default: true;
	};

function main():Int
	return !isPhysical(Get) && !isPhysical(Never) && isPhysical(Default) && isPhysical(null) && read(OptionalValue.Found(40)) + read(null) == 42 ? 42 : 1;
