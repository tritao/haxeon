class Unsafe {
	public static function get():String return null;
	public static function take(s:String) {}
	public var f:String;
	public function new() {}
}

@:nullSafety(Strict)
class Main {
	var a:String; // uninit field
	var b:String = "x";
	var c:Null<String>;
	var arr:Array<String> = [];
	public function new(s:Null<String>) {
		trace(this.b); // read before init done?
		escape(this); // this escaping
		a = "a";
	}
	static function escape(p:Main) {}
	static function ret(s:Null<String>):String return s; // return
	static function arg(s:String) {}
	static function tests(s:Null<String>, d:Dynamic, o:Main) {
		var x:String = s; // assign
		arg(s); // argument
		if (s != null) arg(s); // narrowing ok
		if (s == null) return;
		arg(s); // early return narrowing
		var t:Null<String> = null;
		var y:String = d; // Dynamic boundary
		var z:String = Reflect.field(o, "a"); // reflect
		var w:String = cast t; // unsafe cast
		var w2:String = (t:String); // check type
		var u:String = Unsafe.get(); // non-null-safe call result
		Unsafe.take(t); // passing null to unsafe
		var uf:String = new Unsafe().f;
		var l:Null<String> = o.c;
		var len = l.length; // field access on nullable
		var len2 = l == null ? 0 : l.length; // checked
		var q:String = l ?? "d"; // ??
		if (o.c != null) arg(o.c); // field narrowing (Strict: no)
		var m = new Map<String, String>();
		var mv:String = m.get("k"); // map get
		var ae:String = o.arr[5]; // array read
		var std:Int = Std.parseInt("1"); // Null<Int>
		var fn:Null<String->Void> = null;
		fn("x");
		var loc:Null<String> = s;
		loc = t;
		if (loc != null) {
			var cl = () -> arg(loc);
			arg(loc);
		}
	}
	static function main() {}
}
