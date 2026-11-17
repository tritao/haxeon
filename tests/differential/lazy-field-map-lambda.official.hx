class Main {
	static var names = ["ada", "grace"];
	static var upper = names.map(s -> s.toUpperCase());
	static var lengths = names.map(s -> s.length);
	static var twice = (x:Int) -> x * 2;
	static var greet = function(name:String):String return "hello " + name;

	var scale = (x:Float) -> x * 1.5;

	function new() {}

	static function main() {
		var count:Int = lengths[1];
		var shout:String = upper[0];
		var t = twice;
		var g = greet;
		var m = new Main();
		var s = m.scale;
		Sys.println(upper);
		Sys.println(count + t(3));
		Sys.println(shout + " " + g("world"));
		Sys.println(s(2));
	}
}
