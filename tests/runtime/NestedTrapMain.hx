import compiler.hl.HlCode;
import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.HlFunction;
import compiler.hl.HlFunction.HlInstruction;
import compiler.hl.HlType;
import compiler.hl.HlWriter;
import sys.io.File;

/** Emits consecutive EndTrap opcodes on an early return from nested handlers. */
class NestedTrapMain {
	static function main():Void {
		var code = new HlCode();
		code.types = [
			Simple(HlType.Void),
			Simple(HlType.I32),
			Simple(HlType.Dyn),
			Function([], 1),
			Function([1], 0)
		];
		code.ints = [7, 8, 9, 13, 42];
		code.strings = ["std", "sys_exit"];
		code.natives = [
			{
				library: 0,
				name: 1,
				type: 4,
				functionIndex: 0
			}
		];
		code.functions = [
			new HlFunction(3, 1, [1, 2, 2], [
				Trap(1, "outer"),
				Trap(2, "inner"),
				LoadInt(0, 0),
				EndTrap(2),
				EndTrap(1),
				Return(0),
				Label("inner"),
				LoadInt(0, 1),
				EndTrap(1),
				Return(0),
				Label("outer"),
				LoadInt(0, 2),
				Return(0)
			]),
			new HlFunction(3, 2, [1, 2, 1, 0], [
				Trap(1, "caught"),
				Call0(0, 1),
				LoadInt(2, 3),
				ToDyn(1, 2),
				Throw(1),
				Label("caught"),
				LoadInt(0, 4),
				Call1(3, 0, 0),
				Return(0)
			])
		];
		code.entryPoint = 2;
		File.saveBytes(Sys.args()[0], HlWriter.encode(code));
	}
}
