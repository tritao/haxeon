function length(value:Null<Array<String>>):Int
	return value == null ? 42 : value.length;

function main():Int
	return length(null);
