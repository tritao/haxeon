package haxeon.ui.core;

/**
 * Accumulates a cache key from numbers and strings without building a string. Two 32-bit lanes with different mixing
 * make an accidental match between two different keys about as unlikely as a 64-bit hash collision. Reuse one instance
 * with `reset`: nothing here allocates. Floats count to a resolution of 2^-24.
 */
class KeyHash {
	static inline var SeedA = 0x811c9dc5;
	static inline var SeedB = 0x2545f491;
	static inline var PrimeA = 16777619;

	public var a(default, null):Int = SeedA;
	public var b(default, null):Int = SeedB;

	public function new() {}

	public function reset():KeyHash {
		a = SeedA;
		b = SeedB;
		return this;
	}

	public function addInt(value:Int):KeyHash {
		a = (a ^ value) * PrimeA;
		b ^= value + 0x9e3779b9 + (b << 6) + (b >>> 2);
		return this;
	}

	public function addBool(value:Bool):KeyHash
		return addInt(value ? 1 : 0);

	public function addFloat(value:Float):KeyHash {
		if (value != value)
			return addInt(0x7fc00000);
		if (value >= 2147483647.0)
			return addInt(2147483647).addInt(1);
		if (value <= -2147483647.0)
			return addInt(-2147483647).addInt(-1);
		var whole = Std.int(value);
		return addInt(whole).addInt(Std.int((value - whole) * 16777216.0));
	}

	/** The length goes in first, so ("ab", "c") and ("a", "bc") differ. */
	public function addString(value:Null<String>):KeyHash {
		if (value == null)
			return addInt(-1);
		var length = value.length;
		addInt(length);
		for (index in 0...length)
			addInt(StringTools.fastCodeAt(value, index));
		return this;
	}
}
