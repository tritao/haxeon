import compiler.core.InternalError;
import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrVerifier;

/** `IrVerifier` accepts a loop entered through its header and rejects a cycle with two entries (`IrReducibility`). */
class IrReducibilityMain {
	/** `entry` branches to `left` or `right`, which jump to each other; with `twoEntries` false, `entry` goes only to `left`. */
	static function cycle(twoEntries:Bool):IrProgram {
		var builder = new IrBuilder(),
			condition = builder.argument("condition", Bool),
			left = builder.createBlock(),
			right = builder.createBlock(),
			exit = builder.createBlock();
		if (twoEntries)
			builder.branch(condition, left, right);
		else
			builder.jump(left);
		builder.select(left);
		builder.branch(condition, right, exit);
		builder.select(right);
		builder.jump(left);
		builder.select(exit);
		builder.returnValue(builder.constInt(0));
		var program = new IrProgram("main");
		program.functions.push(new IrFunction("main", builder.arguments, I32, builder.blocks, Ordinary));
		return program;
	}

	static function main():Void {
		IrVerifier.verify(cycle(false));
		try {
			IrVerifier.verify(cycle(true));
		} catch (error:InternalError) {
			if (error.message.indexOf("irreducible control flow") < 0)
				throw error;
			return;
		}
		throw "Verifier accepted a cycle entered at two blocks";
	}
}
