// A constructor call pattern of another enum than the subject's is rejected, qualified or not.
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
		var instruction = Move(1);
		switch instruction {
			case Terminator.Jump(_):
				Sys.println("jump");
			case _:
				Sys.println("other");
		}
	}
}
