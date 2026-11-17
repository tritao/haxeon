// A call through a function value may omit the arguments its type flags optional, as in Haxe: it passes null and the
// function fills its own default. A method value and a static function reference bind the dispatch entry, and a
// lambda or local function fills value-type defaults itself.
class A {
	public function new() {}
	public function f(x:Int, step:Int = 3, ?label:String = "l",
			flag:Bool = true):String return x + " " + step + " " + label + " " + flag;
	public static function s(a:Int, b:Float = 0.5, ?c:Int):String return a + " " + b + " " + c;
}
class Main {
	static function main() {
		var a = new A();
		var f = a.f;
		Sys.println(f(1));
		Sys.println(f(1, 2));
		Sys.println(f(1, 2, null));
		Sys.println(f(1, 5, "x", false));
		var s = A.s;
		Sys.println(s(1));
		Sys.println(s(2, 1.5));
		Sys.println(s(3, 2.5, 4));
		var typed:(x:Int, ?step:Int) -> String = function(x:Int, step:Int = 6) return x + ":" + step;
		Sys.println(typed(1));
		Sys.println(typed(1, 2));
		var opt:(?n:Int) -> Int = function(?n:Int = 8) return n;
		Sys.println(opt());
		Sys.println(opt(1));
		function loc(x:Int = 4, ?y:String = "y") return x + y;
		var h = loc;
		Sys.println(h());
		Sys.println(loc(2));
		Sys.exit(0);
	}
}
