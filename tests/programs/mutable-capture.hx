function use(start:Int):Int {
	var next = () -> {
		start++;
		return start;
	};
	return next() + next();
}

function main():Int {
	var offset = 1;
	var next = () -> {
		offset++;
		return offset;
	};
	var read = () -> {
		return offset;
	};
	offset = 10;
	return next() + next() + read() + use(20);
}
