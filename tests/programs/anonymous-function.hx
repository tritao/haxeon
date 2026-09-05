function apply(callback:(Int) -> Int):Int {
	return callback(41);
}

function main():Int {
	return apply(function(value) return value + 1);
}
