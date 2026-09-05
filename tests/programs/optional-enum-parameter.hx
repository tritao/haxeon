enum Result {
	Value(value:Int, ?message:String);
}

function main():Int {
	var result:Result = Result.Value(42);
	return switch result {
		case Result.Value(value): value;
	};
}
