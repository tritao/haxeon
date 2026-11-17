// A tuple switch without a default must cover every tuple; here [Move(_), Return] is unmatched, which Haxe also rejects.
enum Instruction {
	Phi(out:Int);
	Move(target:Int);
}

enum Terminator {
	Jump(target:Int);
	Return;
}

class Main {
	static function main() {
		var instruction = Move(1), terminator = Return;
		switch [instruction, terminator] {
			case [Phi(_), _]:
				Sys.println("phi");
			case [Move(_), Jump(_)]:
				Sys.println("move, jump");
		}
	}
}
