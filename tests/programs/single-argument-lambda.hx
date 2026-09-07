function apply(callback:(Int) -> Int):Int {
	return callback(42);
}

function main():Int {
	return apply(value -> value + 1);
}
