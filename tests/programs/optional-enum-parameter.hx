enum Reply {
	Value(value:Int, ?message:String);
}

function main():Int {
	var result:Reply = Reply.Value(42);
	return switch result {
		case Reply.Value(value): value;
	};
}
