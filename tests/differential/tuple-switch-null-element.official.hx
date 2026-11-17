// A tuple switch without a default covers every tuple of non-null values. A null enum element that no arm matches
// fails as in Haxe, whose matcher reads the null element's constructor: with a null access.
enum Instruction {
	Move(target:Int);
	Halt;
}

enum Terminator {
	Jump(target:Int);
	Return;
}

class Main {
	static function describe(instruction:Null<Instruction>, terminator:Terminator):String {
		return switch [instruction, terminator] {
			case [Move(_), _]: "move";
			case [Halt, Jump(_)]: "halt, jump";
			case [Halt, Return]: "halt, return";
		}
	}

	static function main() {
		var instruction:Null<Instruction> = null;
		try {
			switch [instruction, Return] {
				case [Move(_), _]:
					Sys.println("move");
				case [Halt, _]:
					Sys.println("halt");
			}
			Sys.println("statement fell through");
		} catch (error:Dynamic) {
			Sys.println("statement: " + Std.string(error));
		}
		try {
			Sys.println(describe(null, Return));
		} catch (error:Dynamic) {
			Sys.println("expression: " + Std.string(error));
		}
		Sys.println(describe(Halt, Return));
		Sys.println(describe(Move(1), Jump(2)));
	}
}
