import compiler.Frontend;
import compiler.hl.HlFunction.HlInstruction;
import compiler.hl.HlValidator;
import compiler.hl.lower.HlLower;

/**
 * Every instruction that can run while a trap is active lies between the trap and its handler, as the HashLink JIT assumes
 * (it keeps a try's registers for the catch over that range). Lowered try/catch code satisfies it; an instruction of the try
 * moved past the handler, reached by a jump out and returning by a jump back, is rejected.
 */
class HlTrapRegionMain {
	static function main():Void {
		var code =
			HlLower.lower(Frontend.compile("
			@:noInline function fail(n:Int):Int { if (n > 1) throw 'stop'; return n; }
			function main():Int {
				var total = 0;
				try {
					total = fail(1) + 1;
					total = fail(2) + total;
				} catch (e:String) {
					total += 40;
				}
				return total;
			}
		"));
		HlValidator.validate(code, null, false);
		Sys.println("PASS: lowered try/catch keeps its protected instructions between the trap and its handler");

		var tampered = false;
		for (fn in code.functions) {
			var trap = -1;
			for (index in 0...fn.opcodes.length)
				switch fn.opcodes[index] {
					case Trap(_, _, _) if (trap < 0):
						trap = index;
					default:
				}
			if (trap < 0)
				continue;
			// The first call inside the try runs out of line, after everything else, and jumps back.
			var moved = -1;
			for (index in trap + 1...fn.opcodes.length)
				switch fn.opcodes[index] {
					case Call1(_, _, _), Call2(_, _, _, _), CallN(_, _, _) if (moved < 0):
						moved = index;
					default:
				}
			var instruction = fn.opcodes[moved], back = 0;
			for (opcode in fn.opcodes)
				switch opcode {
					case Label(id) if (id >= back):
						back = id + 1;
					default:
				}
			var out = back + 1;
			fn.opcodes[moved] = HlInstruction.Jump(out);
			fn.opcodes.insert(moved + 1, HlInstruction.Label(back));
			fn.opcodes.push(HlInstruction.Label(out));
			fn.opcodes.push(instruction);
			fn.opcodes.push(HlInstruction.Jump(back));
			// One debug location per instruction: the moved one keeps its own.
			if (fn.debugLocations.length > 0) {
				var location = fn.debugLocations[moved];
				fn.debugLocations.insert(moved + 1, location);
				for (_ in 0...3)
					fn.debugLocations.push(location);
			}
			tampered = true;
			break;
		}
		expect(tampered, "the program has a function with a trap");
		var rejected = false;
		try
			HlValidator.validate(code, null, false)
		catch (error:Dynamic)
			rejected = Std.string(error).indexOf("is not between it and its handler") >= 0;
		expect(rejected, "an instruction of the try placed after its handler is rejected");
		Sys.println("PASS: an instruction that runs inside a trap but lies past its handler is rejected");
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
