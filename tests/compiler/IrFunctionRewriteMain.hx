import compiler.compilation.AllocationMeter;
import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrFunctionRewrite;
import compiler.ir.SourceProvenance.Located;

/**
 * IrFunctionRewrite is copy-on-write: a rule that replaces nothing gets the same function back and allocates nothing; a rule that
 * replaces one instruction costs one new block and one new function, and every other block is shared.
 */
class IrFunctionRewriteMain {
	static function keep(_:Located<IrInstruction>):Null<Array<Located<IrInstruction>>>
		return null;

	static function threeForTwo(located:Located<IrInstruction>):Null<Array<Located<IrInstruction>>>
		return switch located.value {
			case ConstInt(out, 2): [new Located(ConstInt(out, 3), located.provenance)];
			default: null;
		};

	static function main():Void {
		var b = new IrBuilder(), first = b.currentBlock();
		var one = b.constInt(1), second = b.createBlock(), third = b.createBlock();
		b.jump(second);
		b.select(second);
		var two = b.constInt(2);
		b.jump(third);
		b.select(third);
		b.returnValue(b.add(one, two));
		var fn = new IrFunction("sample", b.arguments, I32, b.blocks, None);

		var unchanged = IrFunctionRewrite.instructions(fn, keep);
		expect(unchanged == fn, "a rule that replaces nothing must return the same function object");
		// The collector counts allocations in lumps (a thread's buffer is counted when it is reserved, up to 256 blocks at once), so a
		// single call cannot be measured. Many calls must count far fewer allocations than one for each of them.
		var before = AllocationMeter.sample();
		for (i in 0...2000)
			IrFunctionRewrite.instructions(fn, keep);
		var after = AllocationMeter.sample();
		expect(after.count - before.count < 1000, "a rule that replaces nothing must allocate nothing");

		var changed = IrFunctionRewrite.instructions(fn, threeForTwo);
		expect(changed != fn && changed.name == fn.name && changed.result == fn.result && changed.arguments == fn.arguments, "one change makes a new function");
		expect(changed.blocks.length == fn.blocks.length, "the blocks keep their number");
		expect(changed.blocks[0] == fn.blocks[0] && changed.blocks[2] == fn.blocks[2], "blocks without a change are shared");
		expect(changed.blocks[1] != fn.blocks[1], "the changed block is copied");
		expect(switch changed.blocks[1].instructions[0].value { case ConstInt(_, 3): true; default: false; }, "the instruction is replaced");
		expect(switch fn.blocks[1].instructions[0].value { case ConstInt(_, 2): true; default: false; }, "the original function is untouched");
		expect(changed.blocks[1].terminator == fn.blocks[1].terminator, "the copied block keeps its terminator");
		Sys.println("PASS: copy-on-write instruction rewriting");
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
