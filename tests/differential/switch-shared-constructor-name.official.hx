// A constructor name both enums declare names the one of the enum being matched, in plain, nested, array and tuple
// patterns alike.
enum Instruction {
	Move(target:Int);
	Return;
}

enum Terminator {
	Jump(target:Int);
	Return;
}

enum Block {
	Last(instruction:Instruction, terminator:Terminator);
}

class Main {
	static function instruction(value:Instruction):String
		return switch value {
			case Return: "instruction return";
			case Move(target): 'move $target';
		}

	static function terminator(value:Terminator):String
		return switch value {
			case Return: "terminator return";
			case Jump(target): 'jump $target';
		}

	static function main() {
		var move:Instruction = Move(1), stop:Instruction = Return, done:Terminator = Return;
		Sys.println(instruction(move));
		Sys.println(instruction(stop));
		Sys.println(terminator(done));
		Sys.println(terminator(Jump(2)));
		for (block in [Last(stop, done), Last(move, Jump(3)), Last(stop, Jump(4))])
			switch block {
				case Last(Return, Return):
					Sys.println("block return, return");
				case Last(Return, Jump(target)):
					Sys.println('block return, jump $target');
				case Last(_, _):
					Sys.println("block other");
			}
		var instructions:Array<Instruction> = [Return];
		switch instructions {
			case [Return]:
				Sys.println("array return");
			case _:
				Sys.println("array other");
		}
		for (pair in [{i: stop, t: done}, {i: stop, t: Jump(5)}, {i: move, t: done}])
			switch [pair.i, pair.t] {
				case [Return, Return]:
					Sys.println("tuple return, return");
				case [Return, Jump(target)]:
					Sys.println('tuple return, jump $target');
				case [Move(target), _]:
					Sys.println('tuple move $target');
			}
	}
}
