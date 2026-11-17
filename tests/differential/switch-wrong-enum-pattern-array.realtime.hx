// An array pattern's elements are resolved against the element type: a constructor of another enum is rejected.
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
		var instructions = [Halt];
		switch instructions {
			case [Return]:
				Sys.println("return");
			case _:
				Sys.println("other");
		}
	}
}
