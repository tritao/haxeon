enum Value {
	Number(value:Int);
	Text(value:String);
}

function describe(value:Value):Int
	return switch value {
		case Number(number): number;
		case whole: switch whole {
			case Text(_): 42;
			case _: 0;
		};
	};

function describeStatement(value:Value):Int {
	var result = 0;
	switch value {
		case Number(number): result = number;
		case whole: result = switch whole {
			case Text(_): 42;
			case _: 0;
		};
	}
	return result;
}

function main():Int
	return describe(Text("answer")) == 42 ? describeStatement(Text("answer")) : 0;
