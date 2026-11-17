// A case pattern naming a constructor of another enum than the subject's is rejected ("Term should be Ins"), never
// matched by constructor index.
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
		var instruction = Halt;
		switch instruction {
			case Return:
				Sys.println("return");
			case _:
				Sys.println("other");
		}
	}
}
