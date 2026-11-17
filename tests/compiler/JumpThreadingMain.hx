import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrInterpreter;
import compiler.ir.IrJumpThreading;
import compiler.ir.IrVerifier;
import compiler.ir.SourceProvenance;
import compiler.ir.SourceProvenance.Located;
import compiler.ir.codec.IrFunctionStateCodec;

class JumpThreadingMain {
	static function expect(value:Bool, message:String):Void {
		if (!value) throw message;
	}
	static function verify(fn:IrFunction, whenTrue:Int, whenFalse:Int):Void {
		var program = new IrProgram("main");
		program.functions = [fn];
		IrVerifier.verify(program);
		var interpreter = new IrInterpreter(program);
		expect(interpreter.run("main", [true]) == whenTrue && interpreter.run("main", [false]) == whenFalse,
			"edge values changed");
	}
	static function main():Void {
		var b = new IrBuilder(),
			condition = b.argument("condition", Bool),
			first = b.constInt(40),
			second = b.constInt(41);
		var bridge = b.createBlock(), exit = b.createBlock();
		b.branch(condition, bridge, exit);
		b.select(bridge);
		b.jump(exit);
		b.select(exit);
		b.returnValue(b.phi(I32, [{block: 0, value: first}, {block: bridge.id, value: second}]));
		var fn = new IrFunction("main", b.arguments, I32, b.blocks, Ordinary);
		expect(IrJumpThreading.run(fn) == fn, "branch edges are not rewritten");
		verify(fn, 41, 40);

		b = new IrBuilder();
		condition = b.argument("condition", Bool);
		first = b.constInt(42);
		bridge = b.createBlock();
		exit = b.createBlock();
		b.jump(bridge);
		b.select(bridge);
		b.jump(exit);
		b.select(exit);
		b.returnValue(b.phi(I32, [{block: bridge.id, value: first}]));
		fn = new IrFunction("main", b.arguments, I32, b.blocks, Ordinary);
		var bytes = IrFunctionStateCodec.encode(fn), optimized = IrJumpThreading.run(fn);
		expect(optimized.blocks.length == 2, "linear edges thread through the empty block");
		expect(bytes.compare(IrFunctionStateCodec.encode(fn)) == 0, "input remains unchanged");
		expect(IrJumpThreading.run(optimized) == optimized, "pass is idempotent");
		verify(optimized, 42, 42);

		b = new IrBuilder();
		condition = b.argument("condition", Bool);
		first = b.constInt(40);
		second = b.constInt(41);
		var path = b.createBlock();
		bridge = b.createBlock();
		exit = b.createBlock();
		b.branch(condition, path, exit);
		b.select(path);
		b.jump(bridge);
		b.select(bridge);
		b.jump(exit);
		b.select(exit);
		b.returnValue(b.phi(I32, [{block: 0, value: first}, {block: bridge.id, value: second}]));
		fn = new IrFunction("main", b.arguments, I32, b.blocks, Ordinary);
		optimized = IrJumpThreading.run(fn);
		expect(optimized.blocks.length == 3, "threaded linear predecessor replaces the phi edge");
		verify(optimized, 41, 40);

		b = new IrBuilder();
		condition = b.argument("condition", Bool);
		first = b.constInt(42);
		var left = b.createBlock(), right = b.createBlock();
		bridge = b.createBlock();
		exit = b.createBlock();
		b.branch(condition, left, right);
		b.select(left);
		b.jump(bridge);
		b.select(right);
		b.jump(bridge);
		b.select(bridge);
		b.jump(exit);
		b.select(exit);
		b.returnValue(b.phi(I32, [{block: bridge.id, value: first}]));
		fn = new IrFunction("main", b.arguments, I32, b.blocks, Ordinary);
		optimized = IrJumpThreading.run(fn);
		verify(optimized, 42, 42);
		// Both sides of the branch only jump to `bridge`, which has no phis: the branch goes there itself.
		expect(optimized.blocks.length == fn.blocks.length - 2, "empty branch sides thread to a block without phis");

		b = new IrBuilder();
		condition = b.argument("condition", Bool);
		first = b.constInt(42);
		bridge = b.createBlock();
		exit = b.createBlock();
		var unreachable = b.createBlock();
		b.jump(bridge);
		b.select(bridge);
		b.jump(exit);
		b.select(exit);
		b.returnValue(first);
		b.select(unreachable);
		b.jump(bridge);
		fn = new IrFunction("main", b.arguments, I32, b.blocks, Ordinary);
		expect(IrJumpThreading.run(fn) == fn, "an unreachable predecessor cannot be left pointing at a removed block");

		b = new IrBuilder();
		condition = b.argument("condition", Bool);
		first = b.constInt(42);
		for (_ in 0...128) {
			var next = b.createBlock();
			b.jump(next);
			b.select(next);
		}
		b.returnValue(first);
		fn = new IrFunction("main", b.arguments, I32, b.blocks, Ordinary);
		optimized = IrJumpThreading.run(fn);
		expect(optimized.blocks.length == 2, "a whole linear chain is threaded in one analysis");
		verify(optimized, 42, 42);

		b = new IrBuilder();
		condition = b.argument("condition", Bool);
		first = b.constInt(42);
		var firstBridge = b.createBlock(), secondBridge = b.createBlock();
		exit = b.createBlock();
		b.jump(firstBridge);
		b.select(firstBridge);
		b.jump(secondBridge);
		b.select(secondBridge);
		b.jump(exit);
		b.select(exit);
		b.returnValue(b.phi(I32, [{block: secondBridge.id, value: first}]));
		fn = new IrFunction("main", b.arguments, I32, b.blocks, Ordinary);
		optimized = IrJumpThreading.run(fn);
		expect(optimized.blocks.length == 2,
			"a chain of removed blocks maps its final phi to the original predecessor");
		verify(optimized, 42, 42);

		b = new IrBuilder();
		condition = b.argument("condition", Bool);
		first = b.constInt(42);
		bridge = b.createBlock();
		exit = b.createBlock();
		b.blocks[0].instructions.push(new Located(EndTry(0, false), SourceProvenance.generated("test")));
		b.jump(bridge);
		b.select(bridge);
		b.jump(exit);
		b.select(exit);
		b.returnValue(first);
		fn = new IrFunction("main", b.arguments, I32, b.blocks, Ordinary);
		expect(IrJumpThreading.run(fn) == fn, "handler-bearing functions remain unchanged");

		// Both sides of a branch reach a phi block through chains of empty blocks: bridging them would give the phi two inputs
		// from the branch, so neither side is bridged to it.
		b = new IrBuilder();
		condition = b.argument("condition", Bool);
		first = b.constInt(40);
		second = b.constInt(41);
		var leftHead = b.createBlock(),
			leftTail = b.createBlock(),
			rightHead = b.createBlock(),
			rightTail = b.createBlock();
		exit = b.createBlock();
		b.branch(condition, leftHead, rightHead);
		b.select(leftHead);
		b.jump(leftTail);
		b.select(leftTail);
		b.jump(exit);
		b.select(rightHead);
		b.jump(rightTail);
		b.select(rightTail);
		b.jump(exit);
		b.select(exit);
		b.returnValue(b.phi(I32, [{block: leftTail.id, value: first}, {block: rightTail.id, value: second}]));
		fn = new IrFunction("main", b.arguments, I32, b.blocks, Ordinary);
		verify(IrJumpThreading.run(fn), 40, 41);

		// A branch side that only jumps to a block without phis goes there directly.
		b = new IrBuilder();
		condition = b.argument("condition", Bool);
		var empty = b.createBlock(), yes = b.createBlock(), no = b.createBlock();
		b.branch(condition, empty, no);
		b.select(empty);
		b.jump(yes);
		b.select(yes);
		b.returnValue(b.constInt(1));
		b.select(no);
		b.returnValue(b.constInt(2));
		fn = new IrFunction("main", b.arguments, I32, b.blocks, Ordinary);
		optimized = IrJumpThreading.run(fn);
		expect(optimized.blocks.length == fn.blocks.length - 1, "a conditional edge threads past an empty block");
		verify(optimized, 1, 2);

		// `condition || false` made into a Bool and branched on: each constant goes to its side, and the phi block is gone.
		b = new IrBuilder();
		condition = b.argument("condition", Bool);
		var whenTrue = b.createBlock(), whenFalse = b.createBlock(), join = b.createBlock();
		yes = b.createBlock();
		no = b.createBlock();
		b.branch(condition, whenTrue, whenFalse);
		b.select(whenTrue);
		var t = b.constBool(true);
		b.jump(join);
		b.select(whenFalse);
		var f = b.constBool(false);
		b.jump(join);
		b.select(join);
		b.branch(b.phi(Bool, [{block: whenTrue.id, value: t}, {block: whenFalse.id, value: f}]), yes, no);
		b.select(yes);
		b.returnValue(b.constInt(1));
		b.select(no);
		b.returnValue(b.constInt(2));
		fn = new IrFunction("main", b.arguments, I32, b.blocks, Ordinary);
		optimized = IrJumpThreading.threadConstantBranches(fn);
		expect(!Lambda.exists(optimized.blocks, block -> block.id == join.id),
			"a branch on constant phi inputs is threaded");
		verify(optimized, 1, 2);
		// The side a constant selects has a phi: the threaded predecessor gives it what the skipped block gave.
		b = new IrBuilder();
		condition = b.argument("condition", Bool);
		var viaConstant = b.createBlock(), other = b.createBlock();
		join = b.createBlock();
		var merge = b.createBlock(), never = b.createBlock();
		var five = b.constInt(5);
		b.branch(condition, viaConstant, other);
		b.select(viaConstant);
		var constant = b.constBool(true);
		b.jump(join);
		b.select(other);
		var seven = b.constInt(7);
		b.jump(merge);
		b.select(join);
		b.branch(b.phi(Bool, [{block: viaConstant.id, value: constant}]), merge, never);
		b.select(merge);
		b.returnValue(b.phi(I32, [{block: join.id, value: five}, {block: other.id, value: seven}]));
		b.select(never);
		b.returnValue(b.constInt(9));
		fn = new IrFunction("main", b.arguments, I32, b.blocks, Ordinary);
		optimized = IrJumpThreading.threadConstantBranches(fn);
		expect(!Lambda.exists(optimized.blocks, block -> block.id == join.id),
			"a constant is threaded into a block with phis");
		verify(optimized, 5, 7);
		Sys.println("PASS: jump threading preserves phi edges and exception regions, and threads branches on constants");
	}
}
