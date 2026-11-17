// One abstract never converts to another through a third type: `A to Float` and `B from Float` do not make an A a B, in
// Haxe as here ("A should be B").
abstract A(Float) from Float to Float {}
abstract B(Float) from Float {}

class Main {
	static function main() {
		var a:A = 1.5;
		var b:B = a;
	}
}
