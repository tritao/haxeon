// A structure pattern names fields of the value: `missing` is none.
class Main {
	static function main():Void {
		var item = {count: 1};
		switch item {
			case {
				missing:1
			}
			: Sys.println("one");
			case _:
		}
	}
}
