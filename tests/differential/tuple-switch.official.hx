// A switch whose subject is an array literal matches element by element, as Haxe's matcher does: each element keeps its own
// type, the array is never built, and the cases must cover every tuple unless the switch has a default.
enum Instruction {
	Phi(out:Int, inputs:Array<Int>);
	Move(target:Int, source:Int);
	Nop;
}

enum Terminator {
	Branch(condition:Int, yes:Int, no:Int);
	Jump(target:Int);
	Return;
}

class Main {
	static var evaluations:Array<String> = [];

	static function describe(instruction:Instruction, terminator:Terminator):String {
		return switch [instruction, terminator] {
			case [Phi(out, inputs), Branch(condition, yes, no)]: 'phi $out/${inputs.length} branch $condition $yes $no';
			case [Move(target, source), Return] if (target > 3): 'move $target<-$source then return';
			case [Move(target, _), Jump(to)]: 'move $target then jump $to';
			case [Nop, _]: "nop";
			default: "other";
		}
	}

	// No default: the arms cover every pair, so the switch is exhaustive and every path returns.
	static function code(instruction:Instruction, terminator:Terminator):Int {
		switch [instruction, terminator] {
			case [Phi(_, _), _]:
				return 1;
			case [Move(_, _), Branch(_, _, _)]:
				return 2;
			case [Move(_, _), Jump(_) | Return]:
				return 3;
			case [Nop, _]:
				return 4;
		}
	}

	// A nested constructor pattern covers its constructor once other arms fill in the rest.
	static function nested(instruction:Instruction, flag:Bool):String {
		return switch [instruction, flag] {
			case [Move(0, _), true]: "move from zero, set";
			case [Move(_, _), true]: "move, set";
			case [Move(_, _), false]: "move, clear";
			case [Phi(_, _) | Nop, _]: "not a move";
		}
	}

	static function constants(count:Int, name:String):String {
		return switch [count, name] {
			case [1, "one"]: "one by name";
			case [n, label] if (n > 5): 'big $label';
			case [_, "x"]: "any x";
			case _: "anything";
		}
	}

	static function triple(a:Bool, b:Bool, c:Terminator):String {
		return switch [a, b, c] {
			case [true, true, _]: "both";
			case [true, false, Return]: "first, return";
			case [true, false, Jump(n)]: 'first, jump $n';
			case [true, false, Branch(_, _, _)]: "first, branch";
			case [false, _, captured = Jump(_)]: 'neither, $captured';
			case [false, _, _]: "neither";
		}
	}

	static function same(left:Terminator, right:Terminator):String {
		return switch [left, right] {
			case [Return, Return]: "both return";
			case [Jump(a), Jump(b)]: 'jumps $a $b';
			case [_, _]: "differ";
		}
	}

	static function trace_(value:Int, label:String):Int {
		evaluations.push(label);
		return value;
	}

	static function main() {
		Sys.println(describe(Phi(1, [2, 3]), Branch(4, 5, 6)));
		Sys.println(describe(Move(7, 8), Return));
		Sys.println(describe(Move(2, 8), Return));
		Sys.println(describe(Move(2, 8), Jump(9)));
		Sys.println(describe(Nop, Return));
		Sys.println(describe(Phi(1, []), Return));
		var codes = [];
		for (instruction in [Phi(0, []), Move(1, 2), Nop])
			for (terminator in [Branch(1, 2, 3), Jump(4), Return])
				codes.push(code(instruction, terminator));
		Sys.println(codes.join(","));
		Sys.println(nested(Move(0, 1), true) + "; " + nested(Move(2, 1), true) + "; " + nested(Move(2, 1), false) + "; "
			+ nested(Nop, true));
		Sys.println(constants(1, "one") + "; " + constants(9, "nine") + "; " + constants(2, "x") + "; " + constants(2,
			"y"));
		Sys.println([
			triple(true, true, Return), triple(true, false, Return), triple(true, false, Jump(3)),
			triple(true, false, Branch(1, 2, 3)), triple(false, true, Jump(5)), triple(false, false, Return)
		].join("; "));
		Sys.println(same(Return, Return) + "; " + same(Jump(1), Jump(2)) + "; " + same(Jump(1), Return));
		// Elements are evaluated once each, left to right, before any case is tried.
		switch [trace_(1, "first"), trace_(2, "second")] {
			case [2, _]:
				Sys.println("unexpected");
			case [1, second]:
				Sys.println('matched second=$second');
			case _:
				Sys.println("unexpected");
		}
		Sys.println(evaluations.join(","));
	}
}
