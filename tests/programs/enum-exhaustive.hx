enum Color {
	Red;
	Blue;
}

function choose(color:Color):Int {
	switch (color) {
		case Color.Red:
			return 1;
		case Color.Blue:
			return 42;
	}
}

function main():Int {
	return choose(Color.Blue);
}
