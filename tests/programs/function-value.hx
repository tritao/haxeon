function twice(value:Int):Int {
	return value * 2;
}

function main():Int {
	var functions = [twice];
	return functions[0](21);
}
