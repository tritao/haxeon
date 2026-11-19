// Every pattern of a case binds the same names: `x` is bound by `A(x)` but not by `C`.
enum E {
	A(v:Int);
	C;
}

class Main {
	static function main() {
		switch (A(1)) {
			case A(x), C:
				trace(x);
			default:
		}
	}
}
