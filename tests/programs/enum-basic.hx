enum Color {
	Red;
	Blue;
}

function choose(color:Color):Int {
	if (color == Color.Blue)
		return 42;
	return 1;
}

function main():Int {
	return choose(Color.Blue);
}
