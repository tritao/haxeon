import haxe.io.Bytes;

function main():Int {
	var equalLeft = Bytes.ofString("same"),
		equalRight = Bytes.ofString("same"),
		lexicalLeft = Bytes.ofString("o"),
		lexicalRight = Bytes.ofString("p"),
		longer = Bytes.ofString("op"),
		high = Bytes.alloc(1),
		low = Bytes.alloc(1);
	high.set(0, 255);
	low.set(0, 127);
	return equalLeft.compare(equalRight) == 0
		&& lexicalLeft.compare(lexicalRight) < 0
		&& lexicalRight.compare(lexicalLeft) > 0
		&& lexicalLeft.compare(longer) < 0
		&& high.compare(low) > 0 ? 42 : 0;
}
