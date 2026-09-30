class Bits {
	public var mask:Int = 1;
	public var items:Array<Int> = [1, 4, -16];
}

function main():Int {
	var failures = 0;
	var a = 3;
	a <<= 2;
	if (a != 12)
		failures += 1;
	a >>= 1;
	if (a != 6)
		failures += 2;
	var negative = -16;
	negative >>= 2;
	if (negative != -4)
		failures += 4;
	var wide = -1;
	wide >>>= 28;
	if (wide != 15)
		failures += 8;
	var bits = new Bits();
	bits.mask <<= 5;
	if (bits.mask != 32)
		failures += 16;
	bits.items[0] <<= 3;
	bits.items[2] >>>= 28;
	if (bits.items[0] != 8 || bits.items[2] != 15)
		failures += 32;
	var size = 16;
	while (size < 100)
		size <<= 1;
	if (size != 128)
		failures += 64;
	return failures == 0 ? 42 : failures;
}
