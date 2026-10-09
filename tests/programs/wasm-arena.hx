import runtime.memory.Arena;
import runtime.memory.RawPtr;

function main():Int {
	var arena = new Arena(32);
	var first:RawPtr<Int32> = arena.alloc(4);
	first.store(12);
	first.offset(3).store(30);
	var second:RawPtr<Int32> = arena.alloc(20);
	second.offset(19).store(42);
	if (first.load() != 12 || first.offset(3).load() != 30 || second.offset(19).load() != 42)
		return 1;
	arena.reset();
	var reused:RawPtr<Int32> = arena.alloc();
	reused.store(42);
	if (first.load() != 42)
		return 2;
	var i8:RawPtr<Int8> = first.castTo();
	var u8:RawPtr<UInt8> = first.castTo();
	i8.store(-7);
	if (i8.load() != -7 || u8.load() != 249)
		return 3;
	var i16:RawPtr<Int16> = first.castTo();
	var u16:RawPtr<UInt16> = first.castTo();
	i16.store(-1234);
	if (i16.load() != -1234 || u16.load() != 64302)
		return 4;
	var i64:RawPtr<Int64> = first.castTo();
	i64.store(9001);
	if (i64.load() != 9001)
		return 5;
	var f32:RawPtr<Float32> = first.castTo();
	f32.store(1.25);
	if (f32.load() != 1.25)
		return 6;
	var f64:RawPtr<Float64> = first.castTo();
	f64.store(3.5);
	if (f64.load() != 3.5)
		return 7;
	var link:RawPtr<RawPtr<Int32>> = first.castTo();
	link.store(second.offset(19));
	if (link.load().load() != 42)
		return 8;
	arena.dispose();
	arena.dispose();
	return 42;
}
