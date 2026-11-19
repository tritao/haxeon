// Locals that closures capture and write, and locals written in a `try` and read after it: each is one variable however
// many closures and paths reach it.
class Main {
	static function closureWrites():String {
		var count = 0;
		var bump = () -> count++;
		bump();
		count += 10;
		bump();
		return Std.string(count);
	}

	static function readAfterOuterWrite():String {
		var label = "first";
		var read = () -> label;
		label = "second";
		return read();
	}

	static function nested():String {
		var total = 1;
		var outer = () -> {
			var inner = () -> total *= 3;
			inner();
			total += 1;
		};
		outer();
		outer();
		return Std.string(total);
	}

	static function parameter(start:Int):String {
		var add = (n:Int) -> start += n;
		add(2);
		add(3);
		return Std.string(start);
	}

	static function loops():String {
		var sum = 0;
		var adders:Array<() -> Void> = [];
		for (i in 1...4)
			adders.push(() -> sum += i);
		for (add in adders)
			add();
		var j = 0;
		var seen = [];
		while (j < 3) {
			var k = j * 2;
			seen.push(() -> k + j);
			j++;
		}
		return sum + ";" + [for (read in seen) read()].join(",");
	}

	static function recursion():String {
		var calls = 0;
		function walk(n:Int):Int {
			calls++;
			return n <= 0 ? 0 : n + walk(n - 1);
		}
		return walk(4) + "," + calls;
	}

	static function tryEdge(fail:Bool):String {
		var state = "start";
		try {
			state = "inside";
			if (fail)
				throw "stop";
			state = "done";
		} catch (e:String) {
			state += "+" + e;
		}
		return state;
	}

	static function tryCapture():String {
		var log = "";
		var note = (s:String) -> log += s;
		try {
			note("a");
			throw "x";
		} catch (e:String) {
			note(e);
		}
		note("b");
		return log;
	}

	static function main() {
		Sys.println(closureWrites());
		Sys.println(readAfterOuterWrite());
		Sys.println(nested());
		Sys.println(parameter(1));
		Sys.println(loops());
		Sys.println(recursion());
		Sys.println(tryEdge(false) + ";" + tryEdge(true));
		Sys.println(tryCapture());
	}
}
