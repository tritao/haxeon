import haxe.io.Bytes;

function makeView():Bytes {
	var source = Bytes.ofString("abcdef");
	return Bytes.view(source, 1, 4);
}

function main():Int {
	var view = makeView(), pressure = Bytes.alloc(8);
	pressure.set(0, 1);
	if (view.length != 4)
		return 0;
	var snapshot = view.toString(), rangeSnapshot = view.getString(1, 2);
	view.set(0, 42);
	var nested = Bytes.view(view, 1, 2);
	nested.set(1, 43);
	var copy = nested.sub(0, 2);
	copy.set(0, 9);
	if (snapshot != "bcde" || rangeSnapshot != "cd")
		return 2;
	if (view.length != 4)
		return 1;
	if (view.get(0) != 42 || view.get(2) != 43 || nested.get(1) != 43 || copy.get(0) != 9 || view.get(1) != 99)
		return 3;
	return 42;
}
