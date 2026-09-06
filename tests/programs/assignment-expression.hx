function keep(value:Int, assigned:Int):Int {
	return value + assigned;
}

function main():Int {
	var value = 0;
	return keep(0, value = 42);
}
