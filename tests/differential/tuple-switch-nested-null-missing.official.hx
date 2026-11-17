// A nullable enum element switched below another element must match null: Haxe's matcher switches on `instruction` first,
// then on `terminator` under each constructor, and only the first switch may leave null unmatched. Haxe rejects this
// expression switch with "Unmatched patterns: null"; [Move(_), null] is missing.
enum Instruction {
	Move(target:Int);
	Halt;
}

enum Terminator {
	Jump(target:Int);
	Return;
}

class Main {
	static function describe(instruction:Null<Instruction>, terminator:Null<Terminator>):String {
		return switch [instruction, terminator] {
			case [Halt, _]: "halt";
			case [Move(_), Jump(_)]: "move, jump";
			case [Move(_), Return]: "move, return";
		}
	}

	static function main() {
		Sys.println(describe(Halt, null));
	}
}
