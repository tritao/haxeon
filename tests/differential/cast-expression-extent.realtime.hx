// An unsafe cast takes the whole expression to its right (`cast (d) % 2` casts `(d) % 2`, `cast p.twice()` the call);
// a typed cast `cast(value, Type)` ends at its parentheses.
class Point {
	public var x:Int;
	public function new(x:Int)
		this.x = x;
	public function twice():Int
		return x * 2;
}
class Main {
	static function main() {
		var d:Dynamic = 7;
		var i:Int = cast(d) % 2;
		Sys.println(i);
		var p:Dynamic = new Point(5);
		var t:Int = cast p.twice();
		Sys.println(t);
		var q:Point = cast(p);
		Sys.println(q.x);
		var sum:Int = 1 + cast d * 3;
		Sys.println(sum);
		var b:Bool = cast d == 7;
		Sys.println(b);
		var typed = cast(p, Point).twice() + 1;
		Sys.println(typed);
		var f:Float = cast(d) / 2;
		Sys.println(f);
		var arr:Array<Int> = cast[1, 2, 3];
		Sys.println(arr.length);
		var n:Int = cast(d);
		Sys.println(n + 1);
		var len:Int = cast(p).x + 1;
		Sys.println(len);
		var c = true ? cast d : 0;
		Sys.println(c);
	}
}
