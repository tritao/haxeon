// A switch over Bool without a default covers `true` and `false`, as a statement too.
class Main {
	static function main() {
		var b = Std.random(2) == 0;
		switch (b) {
			case true:
				Sys.println("yes");
		}
	}
}
