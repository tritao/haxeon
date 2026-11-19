// A lambda that captures a local and declares one of the same name reads its own where that one is visible, and the
// captured one elsewhere.
class Main {
	static function main() {
		var x = 1;
		var g = () -> {
			var y = x;
			{
				var x = 7;
				y += x;
			}
			return y;
		};
		var h = () -> {
			var total = x;
			for (x in 10...12)
				total += x;
			return total;
		};
		Sys.println(g() + "," + h());
	}
}
