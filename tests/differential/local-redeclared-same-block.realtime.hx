// Haxe lets `var x` declare a new local of the same name in the same block, shadowing the first for the code after it;
// a lambda made before keeps reading the first.
class Main {
	static function main() {
		var x = 1;
		var read = () -> x;
		var x = "ten";
		Sys.println(read() + "," + x);
	}
}
