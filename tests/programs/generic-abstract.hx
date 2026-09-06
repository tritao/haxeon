abstract Identity<T>(T) from T to T {}

function read(value:Identity<Int>):Int
	return value;

function main():Int
	return read(42);
