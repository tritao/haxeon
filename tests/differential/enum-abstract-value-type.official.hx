// A value of an enum abstract has the abstract's type; written as another type, both compilers reject it.
enum abstract Code(Int) {
	var Ok:Int = 0;
}

class Main {
	static function main() {
		Sys.println(Code.Ok);
	}
}
