function values():Array<Int> {
	return new Array<Int>(0);
}

function main():Int {
	return values().push(1) + values().unshift(2) + 40;
}
