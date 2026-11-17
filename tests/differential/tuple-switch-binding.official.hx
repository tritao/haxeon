// The tuple is never built, so no case can bind it; Haxe says "Cannot bind matched tuple to variable, use _ instead".
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
		var result = switch [instruction, terminator] {
			case [Phi(_), _]: 1;
			case pair: 2;
		}
		Sys.println(result);
	}
}
