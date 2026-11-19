// The patterns of one case each bind `x`; a closure in the body captures whichever matched, and sees the body's later write.
enum Shape {
	Wide(size:Int);
	Tall(size:Int);
	Empty;
}

function capture(shape:Shape):Int {
	var read:Void->Int = () -> -1;
	switch shape {
		case Wide(x), Tall(x):
			read = () -> x;
			x += 10;
		case Empty:
	}
	return read();
}

function main():Int {
	var doubled = switch (Tall(5)) {
		case Wide(y), Tall(y): y * 2;
		case Empty: 0;
	};
	return capture(Wide(1)) == 11 && capture(Tall(2)) == 12 && capture(Empty) == -1 && doubled == 10 ? 42 : 1;
}
