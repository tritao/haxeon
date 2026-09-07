enum abstract Flag(Int) from Int to Int {
	var Answer = 2;
}

function main():Int {
	var flags = 2;
	return flags & (Answer : Int) != 0 ? 42 : 0;
}
