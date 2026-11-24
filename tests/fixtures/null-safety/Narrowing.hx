@:nullSafety(MODE)
class Main {
	var f:Null<String>;
	function new() {}
	function sideEffect() f = null;
	function narrowing() {
		if (f != null) {
			sideEffect();
			trace(f.length);
		}
		if (f == null) return;
		trace(f.length);
	}
	static function main() {
		var o:Dynamic = new Main();
		var m:Main = o;
		var c = 0;
		var arr = ["a"];
		var s:String = arr[10];
		trace(s.length);
		var k:Main = cast o;
	}
}
