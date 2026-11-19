// The patterns of one case share its guard and body: each binds the same names, which the body reads whichever matched,
// including from a closure the body makes, and through `|` alternatives and nested patterns.
enum E {
	A(v:Int);
	B(v:Int);
	P(a:Int, b:Int);
	Q(b:Int, a:Int);
	W(e:E);
	C;
}

class Main {
	static function guarded(e:E):String
		return switch e {
			case A(x), B(x) if (x > 1): 'big $x';
			case A(x), B(x): 'small $x';
			case P(a, b), Q(b, a): 'pair ${a - b}';
			case W(A(n) | B(n)): 'wrapped $n';
			case _: 'other';
		};

	static function statements(e:E):Int {
		var total = 0;
		switch e {
			case A(x) | B(x):
				total += x;
				x = 100;
				total += x;
			case W(inner):
				total = statements(inner) * 2;
			default:
		}
		return total;
	}

	static function captured(e:E):Int {
		var read:Void->Int = () -> -1;
		switch e {
			case A(x), B(x):
				read = () -> x;
				x += 10;
			default:
		}
		return read();
	}

	static function main() {
		Sys.println([guarded(A(1)), guarded(B(5)), guarded(P(9, 2)), guarded(Q(9, 2)), guarded(W(B(7))),
			guarded(C)].join(","));
		Sys.println([statements(A(3)), statements(W(B(4))), statements(C)].join(","));
		Sys.println([captured(A(1)), captured(B(2)), captured(C)].join(","));
	}
}
