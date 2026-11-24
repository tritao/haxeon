@:nullSafety(Strict) class Base4 {
	public function new() {
		hook();
	}
	function hook() {}
}
@:nullSafety(Strict) class Kid4 extends Base4 {
	var s:String;
	public function new() {
		super();
		s = "x";
	}
	override function hook() trace(s.length);
}
@:nullSafety(Strict) class G4 {
	public static function id<T>(x:T):T return x;
	public static function len(s:String) {
		if (s == null) return 0;
		return s.length;
	}
}
class Main {
	static function main() {
		var n:Null<String> = null;
		var r = G4.id(n);
		trace(G4.len(null));
		new Kid4();
	}
}
