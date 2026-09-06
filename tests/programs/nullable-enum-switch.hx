enum OptionalValue {
	Found(value:Int);
	Missing;
}

function read(value:Null<OptionalValue>):Int {
	return switch value {
		case OptionalValue.Found(result): result;
		case OptionalValue.Missing: 1;
		case null: 2;
	};
}

function main():Int {
	var present:Null<OptionalValue> = OptionalValue.Found(40);
	var absent:Null<OptionalValue> = null;
	return read(present) + read(absent);
}
