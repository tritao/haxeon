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
	static function expect(value:Bool, message:String):Void { if (!value) throw message; }
	static function verify(fn:IrFunction, whenTrue:Int, whenFalse:Int):Void {
		var program = new IrProgram("main"); program.functions = [fn]; IrVerifier.verify(program);
		var interpreter = new IrInterpreter(program);
		expect(interpreter.run("main", [true]) == whenTrue && interpreter.run("main", [false]) == whenFalse, "edge values changed");
	}
	static function main():Void {
		var b = new IrBuilder(), condition = b.argument("condition", Bool), first = b.constInt(40), second = b.constInt(41);
		var bridge = b.createBlock(), exit = b.createBlock(); b.branch(condition, bridge, exit);
		b.select(bridge); b.jump(exit);
		b.select(exit); b.returnValue(b.phi(I32, [{block: 0, value: first}, {block: bridge.id, value: second}]));
		var fn = new IrFunction("main", b.arguments, I32, b.blocks, None, []);
		expect(IrJumpThreading.run(fn) == fn, "branch edges are not rewritten");
		verify(fn, 41, 40);

		b = new IrBuilder(); condition = b.argument("condition", Bool); first = b.constInt(42);
		bridge = b.createBlock(); exit = b.createBlock(); b.jump(bridge);
		b.select(bridge); b.jump(exit);
		b.select(exit); b.returnValue(b.phi(I32, [{block: bridge.id, value: first}]));
		fn = new IrFunction("main", b.arguments, I32, b.blocks, None, []);
		var bytes = IrFunctionStateCodec.encode(fn), optimized = IrJumpThreading.run(fn);
		expect(optimized.blocks.length == 2, "linear edges thread through the empty block");
		expect(bytes.compare(IrFunctionStateCodec.encode(fn)) == 0, "input remains unchanged");
		expect(IrJumpThreading.run(optimized) == optimized, "pass is idempotent");
		verify(optimized, 42, 42);

		b = new IrBuilder(); condition = b.argument("condition", Bool); first = b.constInt(40); second = b.constInt(41);
		var path = b.createBlock(); bridge = b.createBlock(); exit = b.createBlock(); b.branch(condition, path, exit);
		b.select(path); b.jump(bridge); b.select(bridge); b.jump(exit);
		b.select(exit); b.returnValue(b.phi(I32, [{block: 0, value: first}, {block: bridge.id, value: second}]));
		fn = new IrFunction("main", b.arguments, I32, b.blocks, None, []); optimized = IrJumpThreading.run(fn);
		expect(optimized.blocks.length == 3, "threaded linear predecessor replaces the phi edge");
		verify(optimized, 41, 40);

		b = new IrBuilder(); condition = b.argument("condition", Bool); first = b.constInt(42);
		var left = b.createBlock(), right = b.createBlock(); bridge = b.createBlock(); exit = b.createBlock();
		b.branch(condition, left, right);
		b.select(left); b.jump(bridge);
		b.select(right); b.jump(bridge);
		b.select(bridge); b.jump(exit);
		b.select(exit); b.returnValue(b.phi(I32, [{block: bridge.id, value: first}]));
		fn = new IrFunction("main", b.arguments, I32, b.blocks, None, []); optimized = IrJumpThreading.run(fn);
		verify(optimized, 42, 42);
		expect(optimized == fn, "multiple predecessor edges remain unchanged");

		b = new IrBuilder(); condition = b.argument("condition", Bool); first = b.constInt(42);
		bridge = b.createBlock(); exit = b.createBlock(); var unreachable = b.createBlock();
		b.jump(bridge); b.select(bridge); b.jump(exit); b.select(exit); b.returnValue(first); b.select(unreachable); b.jump(bridge);
		fn = new IrFunction("main", b.arguments, I32, b.blocks, None, []);
		expect(IrJumpThreading.run(fn) == fn, "an unreachable predecessor cannot be left pointing at a removed block");

		b = new IrBuilder(); condition = b.argument("condition", Bool); first = b.constInt(42);
		for (_ in 0...128) {
			var next = b.createBlock(); b.jump(next); b.select(next);
		}
		b.returnValue(first); fn = new IrFunction("main", b.arguments, I32, b.blocks, None, []); optimized = IrJumpThreading.run(fn);
		expect(optimized.blocks.length == 2, "a whole linear chain is threaded in one analysis");
		verify(optimized, 42, 42);

		b = new IrBuilder(); condition = b.argument("condition", Bool); first = b.constInt(42);
		var firstBridge = b.createBlock(), secondBridge = b.createBlock(); exit = b.createBlock();
		b.jump(firstBridge); b.select(firstBridge); b.jump(secondBridge); b.select(secondBridge); b.jump(exit);
		b.select(exit); b.returnValue(b.phi(I32, [{block: secondBridge.id, value: first}]));
		fn = new IrFunction("main", b.arguments, I32, b.blocks, None, []); optimized = IrJumpThreading.run(fn);
		expect(optimized.blocks.length == 2, "a chain of removed blocks maps its final phi to the original predecessor");
		verify(optimized, 42, 42);

		b = new IrBuilder(); condition = b.argument("condition", Bool); first = b.constInt(42);
		bridge = b.createBlock(); exit = b.createBlock();
		b.blocks[0].instructions.push(new Located(EndTry(0, false), SourceProvenance.generated("test")));
		b.jump(bridge); b.select(bridge); b.jump(exit); b.select(exit); b.returnValue(first);
		fn = new IrFunction("main", b.arguments, I32, b.blocks, None, []);
		expect(IrJumpThreading.run(fn) == fn, "handler-bearing functions remain unchanged");
		Sys.println("PASS: jump threading preserves phi edges and exception regions");
	}
}
