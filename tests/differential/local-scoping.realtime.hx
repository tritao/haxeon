// How names resolve to locals: sibling and nested blocks, lambdas that read an outer name a later declaration shadows,
// loop variables captured per iteration, a closure made in one iteration and run in the next, catches, local recursion,
// pattern bindings in guards, and comprehension variables.
enum Shape {
	Box(size:Int);
	Pair(a:Int, b:Int);
}

class Main {
	static function siblings():String {
		var out = [];
		var x = 1;
		{
			var x = 2;
			out.push(x);
		}
		{
			var x = "three";
			out.push(x.length);
		}
		out.push(x);
		return out.join(",");
	}

	static function lambdaBeforeShadow():String {
		var x = 1;
		var read = () -> x;
		{
			var x = 10;
			x++;
			return read() + "," + x;
		}
	}

	static function loopCaptures():String {
		var readers:Array<() -> Int> = [];
		for (i in 0...3)
			readers.push(() -> i * 10);
		return [for (read in readers) read()].join(",");
	}

	static function closureAcrossIterations():String {
		var total = 0;
		var bump:Null<() -> Void> = null;
		for (i in 0...4) {
			if (bump != null)
				bump();
			bump = () -> total += i;
		}
		return Std.string(total);
	}

	static function catches():String {
		var e = "outer";
		var caught = "";
		try {
			throw "inner";
		} catch (e:String) {
			caught = e;
		}
		return caught + "," + e;
	}

	static function recursion():Int {
		function fib(n:Int):Int
			return n < 2 ? n : fib(n - 1) + fib(n - 2);
		return fib(10);
	}

	static function guards(shape:Shape):String {
		var size = -1;
		return switch shape {
			case Box(size) if (size > 2): 'big $size';
			case Box(size): 'small $size';
			case Pair(a, b) if (a == b): 'same $a';
			case Pair(a, _): 'pair $a,$size';
		};
	}

	static function comprehensions():String {
		var x = 100;
		var squares = [for (x in 0...4) x * x];
		var keyed = [for (x in 0...3) 'k$x' => x + 1];
		return squares.join(",") + ";" + keyed.get("k2") + ";" + x;
	}

	static function main() {
		Sys.println(siblings());
		Sys.println(lambdaBeforeShadow());
		Sys.println(loopCaptures());
		Sys.println(closureAcrossIterations());
		Sys.println(catches());
		Sys.println(recursion());
		Sys.println([guards(Box(5)), guards(Box(1)), guards(Pair(3, 3)), guards(Pair(1, 2))].join(";"));
		Sys.println(comprehensions());
	}
}
