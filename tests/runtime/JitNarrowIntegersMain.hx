/**
 * Integer widths the x86-64 JIT once mistook: UI8/UI16 values compare unsigned (a signed condition put 200 below 100), and a
 * 64-bit integer converts to Float from all 64 bits (the conversion read only the low 32). Compiled by Haxe, not by Haxeon,
 * so it runs the standard bytecode shapes; values pass through functions so the compares are not folded.
 */
class JitNarrowIntegersMain {
	static function less8(a:hl.UI8, b:hl.UI8):Bool
		return a < b;

	static function lessEq8(a:hl.UI8, b:hl.UI8):Bool
		return a <= b;

	static function greater16(a:hl.UI16, b:hl.UI16):Bool
		return a > b;

	static function greaterEq16(a:hl.UI16, b:hl.UI16):Bool
		return a >= b;

	static function toFloat(v:hl.I64):Float
		return (cast v:Float);

	static function check(ok:Bool, message:String):Void {
		if (!ok) {
			Sys.println("FAIL: " + message);
			Sys.exit(1);
		}
	}

	static function main():Void {
		var big8:hl.UI8 = 200, small8:hl.UI8 = 100;
		var big16:hl.UI16 = 50000, small16:hl.UI16 = 1000;
		check(less8(small8, big8) && !less8(big8, small8), "UI8 < compares signed");
		check(!lessEq8(big8, small8) && lessEq8(big8, big8), "UI8 <= compares signed");
		check(greater16(big16, small16) && !greater16(small16, big16), "UI16 > compares signed");
		check(greaterEq16(big16, small16) && greaterEq16(big16, big16), "UI16 >= compares signed");
		var negative:hl.I64 = -5,
			wide:hl.I64 = haxe.Int64.make(-1, 1294967296),
			high:hl.I64 = haxe.Int64.make(1, 0);
		check(toFloat(negative) == -5, "I64 -5 converts to " + toFloat(negative));
		check(toFloat(wide) == -3000000000.0, "I64 -3000000000 converts to " + toFloat(wide));
		check(toFloat(high) == 4294967296.0, "I64 2^32 converts to " + toFloat(high));
		Sys.println("PASS: narrow unsigned compares and 64-bit integer conversions");
	}
}
