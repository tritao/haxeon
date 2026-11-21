// A local inline function is replaced by its body at each call, as in Haxe: its names are the ones it saw where it was
// declared, its arguments are evaluated in order before it runs, and a return in it gives the call's value.
class Main {
	static var log = "";

	static function note(s:String):Int {
		log += s;
		return s.length;
	}

	static function captures(a:Array<Int>):Int {
		var total = 0;
		var k = 3;
		inline function add(x:Int) total += x * k;
		for (v in a)
			add(v);
		return total;
	}

	static function perIteration(n:Int):Int {
		var t = 0;
		for (i in 0...n) {
			inline function sq(y:Int) return y * y + i;
			t += sq(i);
		}
		return t;
	}

	static function shadowing():Int {
		var k = 1;
		inline function f() return k;
		var r = 0;
		{
			var k = 5;
			r = f() * 10 + k;
		}
		return r;
	}

	static function argumentNames(x:Int):Int {
		inline function sub(x:Int, y:Int) return x - y;
		var y = 100;
		return sub(y, x);
	}

	static function order():String {
		log = "";
		inline function f(a:Int, b:Int) {
			log += "f";
			return a - b;
		}
		var r = f(note("x"), note("yy"));
		return log + r;
	}

	static function earlyReturn(y:Int):String {
		inline function g(y:Int):String {
			if (y > 2)
				return "big";
			log += "mid";
			if (y < 0) {
				return "neg";
			}
			return "small";
		}
		log = "";
		return g(y) + g(-y) + g(y + 5) + log;
	}

	static function switchReturn(y:Int):Int {
		inline function g(y:Int):Int {
			switch y {
				case 1:
					return 10;
				case 2, 3:
					return 20;
				default:
					return 30;
			}
		}
		return g(y) + g(y + 1) + g(y + 7);
	}

	static function voidReturn(a:Array<Int>):Array<Int> {
		inline function v(y:Int):Void {
			if (y < 0)
				return;
			a.push(y);
		}
		v(1);
		v(-1);
		v(2);
		return a;
	}

	static function nested(a:Array<Int>):Int {
		var count = 0;
		inline function bump(by:Int) count += by;
		var each = (x:Int) -> bump(x);
		for (x in a)
			each(x);
		bump(100);
		return count;
	}

	static function chained(x:Int):Int {
		inline function twice(y:Int) return y * 2;
		inline function quad(y:Int) return twice(twice(y));
		return quad(x) + twice(1);
	}

	static function declaredResult(x:Int):Float {
		inline function half(y:Int):Float return y / 2;
		return half(x) + half(x + 1);
	}

	static function throws(x:Int):String {
		inline function check(y:Int):Int {
			if (y < 0)
				throw "negative";
			return y;
		}
		try {
			return Std.string(check(x)) + Std.string(check(-x));
		} catch (e:String) {
			return e;
		}
	}

	static function inTry(x:Int):Int {
		var state = 0;
		inline function set(v:Int) {
			state = v;
			if (v > 5)
				throw "big";
		}
		try {
			set(x);
			set(x * 10);
		} catch (e:String) {
			state += 1000;
		}
		return state;
	}

	static function optional(x:Int):Int {
		inline function opt(a:Int, ?b:Int):Int return b == null ? a : a + b;
		return opt(x) + opt(x, 1);
	}

	static function innerInline(x:Int):Int {
		inline function outer(y:Int):Int {
			inline function inner(z:Int) return z + y;
			return inner(1) + inner(2);
		}
		return outer(x) + outer(x * 2);
	}

	static function capturesLambda(x:Int):Int {
		inline function make(y:Int) return () -> x + y;
		return make(1)() + make(2)();
	}

	static function main() {
		Sys.println(captures([1, 2, 3]));
		Sys.println(perIteration(4));
		Sys.println(shadowing());
		Sys.println(argumentNames(7));
		Sys.println(order());
		Sys.println(earlyReturn(1));
		Sys.println(switchReturn(1));
		Sys.println(voidReturn([]));
		Sys.println(nested([1, 2, 3]));
		Sys.println(chained(3));
		Sys.println(declaredResult(3));
		Sys.println(throws(4));
		Sys.println(inTry(1));
		Sys.println(inTry(3));
		Sys.println(optional(5));
		Sys.println(innerInline(10));
		Sys.println(capturesLambda(10));
	}
}
