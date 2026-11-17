// A payload pattern is resolved against the payload's type: a constructor of another enum there is rejected.
enum Instruction {
	Move(target:Int);
	Halt;
}

enum Terminator {
	Jump(target:Int);
	Return;
}

enum Block {
	Last(instruction:Instruction);
}

class Main {
	static function main() {
		var block = Last(Halt);
		switch block {
			case Last(Return):
				Sys.println("return");
			case _:
				Sys.println("other");
		}
	}
}
