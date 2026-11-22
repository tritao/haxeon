// A structure's `function` field is a method: Haxe reports "Cannot rebind this method".
typedef Counter = {
	function next():Int;
}

class Main {
	static function main() {
		var counter:Counter = {next: () -> 1};
		counter.next = () -> 2;
		Sys.println(counter.next());
	}
}
