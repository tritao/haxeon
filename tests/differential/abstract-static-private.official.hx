// A private static of an abstract is reached only from the abstract: "Cannot access private field hidden".
abstract Counter(Int) {
	static var hidden:Int = 1;
}

class Main {
	static function main() {
		Sys.println(Counter.hidden);
	}
}
