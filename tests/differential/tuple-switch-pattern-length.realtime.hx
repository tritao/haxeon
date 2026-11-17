// Each tuple pattern has one element per subject element; Haxe rejects a shorter one ("Not enough arguments").
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
			case [Phi(_)]:
				Sys.println("phi");
			default:
				Sys.println("other");
		}
	}
}
