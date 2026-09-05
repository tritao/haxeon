enum Color {
	Red;
	Blue;
}

function choose(value:Int):Int {
	switch (value) {
		case 1:
			return 0;
		case 2:
			return 42;
		default:
			return 0;
	}
}

function main():Int {
	var color:Color = Color.Blue;
	switch (color) {
		case Color.Red:
			return 0;
		case Color.Blue:
			return choose(2);
		default:
			return 0;
	}
}
