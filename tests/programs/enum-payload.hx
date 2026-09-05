enum Result {
	Ok(Int);
	Error(String);
}

function main():Int {
	var result:Result = Result.Ok(42);
	switch (result) {
		case Result.Ok(value):
			return value;
		case Result.Error(_):
			return 0;
		default:
			return 0;
	}
}
