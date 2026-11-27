enum Reply {
	Ok(Int);
	Error(String);
}

function main():Int {
	var result:Reply = Reply.Ok(42);
	switch (result) {
		case Reply.Ok(value):
			return value;
		case Reply.Error(_):
			return 0;
		default:
			return 0;
	}
}
