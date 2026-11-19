// Every pattern of a case binds a name with one type: `x` is an Int in `A(x)` and a String in `S(x)`.
enum E {
	A(v:Int);
	S(v:String);
}

class Main {
	static function main() {
		switch (A(1)) {
			case A(x), S(x):
				trace(x);
		}
	}
}
