// Each element of a tuple pattern is resolved against its own subject element: a constructor of another enum is
// rejected.
enum Instruction {
	Move(target:Int);
	Halt;
}

enum Terminator {
	Jump(target:Int);
	Return;
}

class Main {
	static function main() {
		var instruction = Halt, terminator = Return;
		switch [instruction, terminator] {
			case [Return, _]:
				Sys.println("return");
			case _:
				Sys.println("other");
		}
	}
}
