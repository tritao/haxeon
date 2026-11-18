// Only the first element a statement decides on may leave values unmatched: under `1`, the second element misses values.
class Main {
	static function main():Void {
		var code = 1;
		switch [code, code] {
			case [1, 2]:
				Sys.println("one, two");
			case [_, 3]:
				Sys.println("three");
		}
	}
}
