@:nullSafety(Strict)
class Base {
	public function m(s:String):Null<String> return s;
	public function new() {}
}
// Overrides that change nullability are left out: a signature that differs from the inherited one is E1020 in Haxeon.
@:nullSafety(Strict)
class Ctor {
	var a:String;
	var b:String;
	var neverSet:String;
	var opt:Int;
	public function new() {
		a = "a";
		helper(); // method call before b set
		var r = a.length;
		var q = b.length; // read before init
		b = "b";
	}
	function helper() trace(b.length);
}
@:nullSafety(Strict)
class Main {
	static var st:String; // static uninit
	static function f(?s:String) {} // optional arg typed String
	static function g(s:String = null) {}
	static function h(x:Int = null) {}
	static function main() {
		var x:String = null;
		var arr:Array<String> = [null];
		var arr2:Array<Null<String>> = ["a"];
		var arr3:Array<String> = arr2;
		var e:{f:String} = {f: null};
		@:nullSafety(Off) var y:String = null;
		var fn:String->Void = function(s:Null<String>) {};
		var fn2:Null<String>->Void = function(s:String) {};
		var it:String = [for (i in 0...1) null][0];
		var n:Null<Int> = null;
		var i:Int = n;
		Unsafe2.cb(function(s:String) trace(s.length)); // callback from unsafe passes null
		var sw:String = switch (n) {
			case null: null;
			case _: "a";
		};
		var dyn:Dynamic = null;
		var ds:String = dyn.foo;
		var o:Unsafe2 = new Unsafe2();
		var us:String = o.field;
		var nested:Null<Main> = null;
		if (nested != null && nested.ok()) {}
		while (x != null) {
			x = null;
		}
	}
	function ok() return true;
}
class Unsafe2 {
	public var field:String;
	public function new() {}
	public static function cb(f:String->Void) f(null);
}
