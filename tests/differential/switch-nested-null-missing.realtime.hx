// A nullable enum argument of a constructor pattern must match null: Haxe's matcher switches on it below the subject,
// where null is not left to the fallback. Haxe rejects this statement switch with "Unmatched patterns: Wait(null)".
enum Instruction {
	Halt;
	Wait(next:Null<Terminator>);
}

enum Terminator {
	Jump(target:Int);
	Return;
}

class Main {
	static function main() {
		var instruction = Wait(null);
		switch instruction {
			case Halt:
				Sys.println("halt");
			case Wait(Jump(_)):
				Sys.println("wait, jump");
			case Wait(Return):
				Sys.println("wait, return");
		}
	}
}
