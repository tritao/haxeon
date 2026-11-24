// Compile without inlining: the hot/cold calls must remain real calls.
class RegallocBench {
	@:noInline static function touch(x:Int):Int {
		return x + 1;
	}

	@:noInline static function baseline(n:Int):Float {
		var sum = 0.0;
		for (i in 0...n)
			sum += (i & 7) * 0.125;
		return sum;
	}

	@:noInline static function hot(n:Int):Float {
		var sum = 0.0;
		for (i in 0...n)
			sum += (touch(i) & 7) * 0.125;
		return sum;
	}

	@:noInline static function cold(n:Int):Float {
		var sum = 0.0;
		for (i in 0...n) {
			if ((i & 1048575) == 0)
				sum += touch(i) * 0.125;
			sum += (i & 7) * 0.125;
		}
		return sum;
	}

	@:noInline static function pressure(n:Int):Int {
		var a = 1, b = 2, c = 3, d = 4, e = 5, f = 6, g = 7;
		for (i in 0...n) {
			var t = touch(i);
			a += t & 1;
			b += t & 2;
			c += t & 3;
			d += t & 4;
			e += t & 5;
			f += t & 6;
			g += t & 7;
		}
		return a + b + c + d + e + f + g;
	}

	@:noInline static function nested(n:Int):Float {
		var sum = 0.0;
		for (i in 0...n) {
			var outer = i * 0.125;
			for (j in 0...8)
				sum += outer + j;
		}
		return sum;
	}

	@:noInline static function conditional(n:Int):Float {
		var sum = 0.0;
		for (i in 0...n) {
			if ((i & 1) == 0)
				sum += 0.125;
			else
				sum += 0.25;
		}
		return sum;
	}

	static function main() {
		var args = Sys.args();
		var n = args.length > 1 ? Std.parseInt(args[1]) : 10000000;
		if (n == null || n < 0)
			throw "invalid count";
		var result:Float = switch (args[0]) {
			case "baseline": baseline(n);
			case "hot": hot(n);
			case "cold": cold(n);
			case "pressure": pressure(n);
			case "nested": nested(n);
			case "conditional": conditional(n);
			default: throw "invalid pattern";
		};
		Sys.println(result);
	}
}
