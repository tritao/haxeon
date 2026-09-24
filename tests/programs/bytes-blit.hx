import haxe.io.Bytes;

function main():Int {
	var source = Bytes.ofString("abcdef");
	var destination = Bytes.alloc(6);
	destination.blit(1, source, 2, 3);
	if (destination.get(0) != 0 || destination.get(1) != 99 || destination.get(2) != 100 || destination.get(3) != 101)
		return 1;
	source.blit(1, source, 0, 4);
	if (source.toString() != "aabcdf")
		return 2;
	var view = Bytes.view(destination, 1, 3);
	view.blit(0, source, 0, 3);
	if (destination.get(1) != 97 || destination.get(2) != 97 || destination.get(3) != 98)
		return 3;
	return 42;
}
