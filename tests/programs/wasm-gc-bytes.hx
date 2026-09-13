import haxe.io.Bytes;

function main():Int {
	var bytes = Bytes.alloc(6);
	bytes.set(0, 0);
	bytes.set(1, 128);
	bytes.set(2, 255);
	bytes.set(3, 42);
	bytes.set(4, 43);
	bytes.set(5, 44);
	var view = Bytes.view(bytes, 1, 3);
	if (view.length != 3 || view.get(0) != 128 || view.get(1) != 255)
		return 0;
	view.set(1, 7);
	var copy = view.sub(1, 2);
	copy.set(0, 9);
	var text = Bytes.ofString("ok"),
		expected = Bytes.alloc(2),
		word = Bytes.alloc(4),
		comparison = Bytes.ofString("o").compare(Bytes.ofString("p"));
	expected.set(0, 9);
	expected.set(1, 42);
	word.setInt32(0, -2147483647);
	var boundsCaught = false;
	try {
		bytes.get(bytes.length);
	} catch (error:Dynamic) {
		boundsCaught = true;
	}
	return bytes.length == 6 && bytes.get(2) == 7 && bytes.get(3) == 42 && copy.get(0) == 9 && copy.compare(expected) == 0
		&& word.getInt32(0) == -2147483647 && text.toString() == "ok" && text.getString(1, 1) == "k" && comparison < 0 && boundsCaught ? 42 : 0;
}
