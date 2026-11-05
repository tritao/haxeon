import runtime.FloatBits;
import haxeon.Hashing;

struct ScalarMapValue {
	public final number:Int;
	public function new(number:Int) this.number = number;
}

struct ScalarMapRecordKey implements Hashable {
	public final number:Int;
	public function new(number:Int) this.number = number;
	public function equals(other:ScalarMapRecordKey):Bool return number % 10 == other.number % 10;
	public function hash():Int return number % 10;
}

enum ScalarMapTag { First; Second; }

class ScalarMapEffects {
	public static var calls:Int = 0;
	public static function next():Float { calls++; return Math.NaN; }
}

class ScalarMapCensus {
	static var values:Map<Float, ScalarMapValue>;
	public static function prepare():Void {
		values = new Map();
		values.set(Math.NaN, new ScalarMapValue(7));
		values.set(1.5, new ScalarMapValue(8));
	}
	public static function perform(n:Int):Int {
		for (_ in 0...n) {
			values.set(Math.NaN, new ScalarMapValue(7));
			var value = values.get(Math.NaN), other = values.get(1.5);
			if (value == null || other == null || value.number != 7 || other.number != 8) return -1;
		}
		return n;
	}
}

function main():Int {
	var floats:Map<Float, Int> = new Map();
	var nan = Math.NaN;
	var otherNaN = FloatBits.fromInt64(haxe.Int64.make(0xfff80000, 1));
	floats.set(nan, 1);
	floats.set(otherNaN, 2);
	if (floats.size() != 1 || floats.get(nan) != 2 || !floats.exists(otherNaN)) return 1;
	floats.set(0.0, 3);
	floats.set(-0.0, 4);
	if (floats.size() != 2 || floats.get(0.0) != 4) return 2;
	floats.set(Math.POSITIVE_INFINITY, 5);
	floats.set(Math.NEGATIVE_INFINITY, 6);
	floats.set(1e100, 7);
	if (floats.get(Math.POSITIVE_INFINITY) != 5 || floats.get(Math.NEGATIVE_INFINITY) != 6 || floats.get(1e100) != 7) return 3;
	if (!floats.remove(otherNaN) || floats.exists(nan)) return 4;
	var bools:Map<Bool, Int> = new Map();
	bools.set(true, 8); bools.set(false, 9);
	if (bools.get(true) != 8 || bools.get(false) != 9) return 5;
	var integers:Map<haxe.Int64, Int> = new Map();
	var big = haxe.Int64.make(1, 7);
	integers.set(big, 10);
	if (integers.get(big) != 10) return 6;
	var nativeIntegers:Map<UInt32, Int> = new Map();
	var unsigned:UInt32 = cast -1;
	nativeIntegers.set(unsigned, 19);
	if (nativeIntegers.get(unsigned) != 19) return 14;
	var unsignedCount = 0;
	for (key in nativeIntegers.keys()) { if (key != unsigned) return 15; unsignedCount++; }
	if (unsignedCount != 1) return 16;
	var optional:Map<Null<ScalarMapTag>, ScalarMapValue> = new Map();
	optional.set(null, new ScalarMapValue(11));
	optional.set(First, new ScalarMapValue(12));
	optional.set(Second, new ScalarMapValue(13));
	var absent = optional.get(null), first = optional.get(First), second = optional.get(Second);
	if (absent == null || first == null || second == null) return 7;
	if (absent.number != 11 || first.number != 12 || second.number != 13) return 8;
	var foundAbsent = false, foundFirst = false, foundSecond = false;
	for (key in optional.keys()) switch key {
		case null: foundAbsent = true;
		case First: foundFirst = true;
		case Second: foundSecond = true;
	}
	if (!foundAbsent || !foundFirst || !foundSecond) return 17;
	var optionalFloats:Map<Null<Float>, Int> = new Map();
	optionalFloats.set(null, 14); optionalFloats.set(nan, 15); optionalFloats.set(otherNaN, 16);
	if (optionalFloats.size() != 2 || optionalFloats.get(null) != 14 || optionalFloats.get(nan) != 16) return 9;
	var records:Map<ScalarMapRecordKey, Int> = new Map();
	records.set(new ScalarMapRecordKey(11), 17);
	records.set(new ScalarMapRecordKey(21), 18);
	if (records.size() != 1 || records.get(new ScalarMapRecordKey(31)) != 18) return 10;
	if (!Hashing.keyEquals(ScalarMapEffects.next(), ScalarMapEffects.next()) || ScalarMapEffects.calls != 2) return 13;
	ScalarMapCensus.prepare();
	#if !wasm
	var before = hl.Gc.totalAllocated();
	#end
	if (ScalarMapCensus.perform(8) != 8 || ScalarMapCensus.perform(1024) != 1024) return 11;
	#if !wasm
	if (hl.Gc.totalAllocated() != before) return 12;
	#end
	return 42;
}
