// Haxe's rule for null in a switch without a default: the switch's own subject need not match null (a null subject fails
// with a null access), while a nullable enum or Bool switched below it, by a tuple column or a constructor argument, must.
enum Instruction {
	Move(target:Int);
	Halt;
	Wait(next:Null<Terminator>);
}

enum Terminator {
	Jump(target:Int);
	Return;
}

class Main {
	static function statement(instruction:Null<Instruction>):Void {
		switch instruction {
			case Move(target):
				Sys.println('move $target');
			case Halt:
				Sys.println("halt");
			case Wait(Jump(target)):
				Sys.println('wait, jump $target');
			case Wait(Return):
				Sys.println("wait, return");
			case Wait(null):
				Sys.println("wait, nothing");
		}
	}

	static function expression(instruction:Null<Instruction>):String {
		return switch instruction {
			case Move(_): "move";
			case Halt: "halt";
			case Wait(_): "wait";
		}
	}

	static function returns(instruction:Null<Instruction>):Int {
		switch instruction {
			case Move(target):
				return target;
			case Halt, Wait(_):
				return -1;
		}
	}

	static function pair(instruction:Instruction, terminator:Null<Terminator>):String {
		return switch [instruction, terminator] {
			case [Move(_), Jump(target)]: 'move, jump $target';
			case [Move(_), Return]: "move, return";
			case [Move(_), null]: "move, nothing";
			case [Halt | Wait(_), _]: "other";
		}
	}

	static function terminatorFirst(instruction:Instruction, terminator:Null<Terminator>):String {
		// The first case constrains only the terminator, so the root switch is on it and needs no null case.
		return switch [instruction, terminator] {
			case [_, Jump(_)]: "jump";
			case [_, Return]: "return";
		}
	}

	static function flag(instruction:Instruction, flag:Null<Bool>):String {
		return switch [instruction, flag] {
			case [Halt, true]: "halt, set";
			case [Halt, false]: "halt, clear";
			case [Halt, null]: "halt, unknown";
			case [_, _]: "other";
		}
	}

	static function main() {
		statement(Move(1));
		statement(Halt);
		statement(Wait(Jump(2)));
		statement(Wait(Return));
		statement(Wait(null));
		try {
			statement(null);
			Sys.println("statement fell through");
		} catch (error:Dynamic) {
			Sys.println('statement: ${Std.string(error)}');
		}
		Sys.println(expression(Wait(null)));
		try {
			Sys.println(expression(null));
		} catch (error:Dynamic) {
			Sys.println('expression: ${Std.string(error)}');
		}
		Sys.println(returns(Move(4)));
		Sys.println(returns(Halt));
		try {
			Sys.println(returns(null));
		} catch (error:Dynamic) {
			Sys.println('returns: ${Std.string(error)}');
		}
		Sys.println(pair(Move(1), Jump(3)));
		Sys.println(pair(Move(1), Return));
		Sys.println(pair(Move(1), null));
		Sys.println(pair(Halt, null));
		Sys.println(terminatorFirst(Halt, Return));
		Sys.println(terminatorFirst(Move(1), Jump(1)));
		Sys.println(flag(Halt, true));
		Sys.println(flag(Halt, false));
		Sys.println(flag(Halt, null));
		Sys.println(flag(Move(1), null));
	}
}
