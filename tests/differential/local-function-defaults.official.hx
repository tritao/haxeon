// Every kind of function fills its own defaults: a local function, a lambda and an arrow function given null for an
// argument with a default replace it, as methods do, through a direct call and through a typed function value.
class Main {
	static function main() {
		function loc(x:Int = 4, ?y:String = "y", ?z:Array<Int>) return x + y + z;
		Sys.println(loc());
		Sys.println(loc(1, null));
		Sys.println(loc(2, "q", [1]));
		var lam = function(?s:String = "s", n:Null<Int> = 9) return s + n;
		Sys.println(lam());
		Sys.println(lam(null, null));
		Sys.println(lam("a", 1));
		var typed:(?s:String, ?n:Null<Int>) -> String = lam;
		Sys.println(typed(null, null));
		var arrow = (?a:String = "arrow") -> a;
		Sys.println(arrow(null));
		var captured = "c";
		var withCapture = function(?t:String = "t") return captured + t;
		Sys.println(withCapture(null));
		Sys.exit(0);
	}
}
// @lint:off function-lambda: this test is about the function form
