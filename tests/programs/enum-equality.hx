// `==` on enums follows Haxe: a constructor without fields denotes one value, and a constructor with fields compares by identity.
enum Shape {
	Dot;
	Circle(r:Int);
	Rect(w:Int, h:Int);
}

enum Plain {
	Red;
	Green;
}

enum Maybe<T> {
	Nothing;
	Just(value:T);
}

function make(w:Int):Shape return Rect(w, 2);

function dot():Shape return Dot;

function maybeShape(flag:Bool):Null<Shape> return flag ? Circle(1) : null;

function nothing():Maybe<Int> return Nothing;

function justOne():Maybe<Int> return Just(1);

function main():Int {
	var failures = 0;
	var a = Circle(1), b = Circle(2), c = Circle(1);

	// Payload constructors compare by identity, not by constructor or contents.
	if (a == b) failures |= 1;
	if (a == c) failures |= 2;
	if (!(a == a)) failures |= 4;
	if (make(1) == make(5)) failures |= 8;
	if (!(a != b)) failures |= 16;
	if (!(a != c)) failures |= 32;
	if (a != a) failures |= 64;

	// A constructor without fields is one value, however it was produced.
	if (!(dot() == Dot)) failures |= 128;
	if (!(Dot == dot())) failures |= 256;
	if (dot() != Dot) failures |= 512;
	if (Dot == a) failures |= 1024;
	if (a == make(1)) failures |= 2048;

	// Nullable enums: null equals only null.
	var none:Null<Shape> = null;
	var some = maybeShape(true);
	if (!(none == null)) failures |= 4096;
	if (some == null) failures |= 8192;
	if (none == some) failures |= 16384;
	if (!(some == some)) failures |= 32768;
	var other:Null<Shape> = null;
	if (!(none == other)) failures |= 65536;
	var nullableDot:Null<Shape> = Dot;
	if (!(nullableDot == Dot)) failures |= 131072;
	if (!(nullableDot == dot())) failures |= 262144;

	// An enum with no payload constructor compares by constructor.
	var red = Red, green = Green;
	if (red == green) failures |= 524288;
	if (!(red == Red)) failures |= 1048576;

	// A generic enum.
	var one = justOne(), same = one;
	if (!(nothing() == nothing())) failures |= 2097152;
	if (one == justOne()) failures |= 4194304;
	if (!(one == same)) failures |= 8388608;

	return failures == 0 ? 42 : (failures & 0xff) == 0 ? 1 : failures & 0xff;
}
