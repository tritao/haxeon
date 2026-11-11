import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrInterpreter;
import compiler.ir.IrReceiverCheck;
import compiler.ir.IrReceiverCheckElision;
import compiler.ir.IrVerifier;
import compiler.ir.SourceProvenance;
import compiler.ir.SourceProvenance.Located;
import compiler.ir.codec.IrFunctionStateCodec;

class ReceiverCheckElisionMain {
	static function expect(value:Bool, message:String):Void { if (!value) throw message; }
	static function check(b:IrBuilder, receiver:IrValue):IrValue return b.call(IrReceiverCheck.NAME, [receiver], Void);
	static function checks(fn:IrFunction):Int {
		var n = 0;
		for (block in fn.blocks) for (located in block.instructions) switch located.value {
			case Call(_, name, _) if (name == IrReceiverCheck.NAME): n++;
			default:
		}
		return n;
	}
	static function program(fn:IrFunction):IrProgram {
		var result = new IrProgram(fn.name);
		result.functions = [fn];
		result.objects = [{name: "Box", isValue: false, base: null, interfaces: [], fields: [], methods: []}];
		return result;
	}
	static function main():Void {
		var b = new IrBuilder(), receiver = b.argument("receiver", Obj("Box")), fresh = b.newObject("Box");
		check(b, fresh); check(b, receiver); check(b, receiver);
		var condition = b.argument("condition", Bool), yes = b.createBlock(), no = b.createBlock(), merge = b.createBlock();
		b.branch(condition, yes, no);
		b.select(yes); check(b, receiver); b.jump(merge);
		b.select(no); b.jump(merge);
		b.select(merge); check(b, receiver); b.returnValue(b.constInt(42));
		var fn = new IrFunction("main", b.arguments, I32, b.blocks, Ordinary), bytes = IrFunctionStateCodec.encode(fn);
		var optimized = IrReceiverCheckElision.run(fn);
		expect(checks(optimized) == 1, "fresh, repeated and dominating checks are eliminated");
		expect(bytes.compare(IrFunctionStateCodec.encode(fn)) == 0, "input remains unchanged");
		expect(IrReceiverCheckElision.run(optimized) == optimized, "pass is idempotent");
		var p = program(optimized); IrVerifier.verify(p);
		var threw = false;
		try new IrInterpreter(p).run("main", [null, true]) catch (_:Dynamic) threw = true;
		expect(threw, "first check must still reject null");

		b = new IrBuilder(); receiver = b.argument("receiver", Obj("Box")); condition = b.argument("condition", Bool);
		yes = b.createBlock(); no = b.createBlock(); merge = b.createBlock(); b.branch(condition, yes, no);
		b.select(yes); check(b, receiver); b.jump(merge);
		b.select(no); b.jump(merge);
		b.select(merge); check(b, receiver); b.returnValue(b.constInt(42));
		fn = new IrFunction("main", b.arguments, I32, b.blocks, Ordinary); optimized = IrReceiverCheckElision.run(fn);
		expect(checks(optimized) == 2, "a check on only one predecessor does not dominate the merge");
		p = program(optimized); IrVerifier.verify(p); threw = false;
		try new IrInterpreter(p).run("main", [null, false]) catch (_:Dynamic) threw = true;
		expect(threw, "unchecked branch must retain its null failure");

		b = new IrBuilder(); receiver = b.argument("receiver", Obj("Box")); condition = b.argument("condition", Bool);
		var header = b.createBlock(), body = b.createBlock(), exit = b.createBlock();
		check(b, receiver); b.jump(header);
		b.select(header); b.branch(condition, body, exit);
		b.select(body); check(b, receiver); b.jump(header);
		b.select(exit); check(b, receiver); b.returnValue(b.constInt(42));
		fn = new IrFunction("main", b.arguments, I32, b.blocks, Ordinary); optimized = IrReceiverCheckElision.run(fn);
		expect(checks(optimized) == 1, "a pre-loop check dominates checks on both loop and exit edges");
		IrVerifier.verify(program(optimized));

		b = new IrBuilder(); receiver = b.argument("receiver", Obj("Box")); condition = b.argument("condition", Bool);
		header = b.createBlock(); body = b.createBlock(); exit = b.createBlock(); b.jump(header);
		b.select(header); b.branch(condition, body, exit);
		b.select(body); check(b, receiver); b.jump(header);
		b.select(exit); check(b, receiver); b.returnValue(b.constInt(42));
		fn = new IrFunction("main", b.arguments, I32, b.blocks, Ordinary); optimized = IrReceiverCheckElision.run(fn);
		expect(checks(optimized) == 2, "a back-edge check must not justify the first iteration or exit");
		p = program(optimized); IrVerifier.verify(p); threw = false;
		try new IrInterpreter(p).run("main", [null, false]) catch (_:Dynamic) threw = true;
		expect(threw, "zero iterations still check the receiver");

		b = new IrBuilder(); receiver = b.argument("receiver", Obj("Box"));
		var checked = check(b, receiver); check(b, receiver); b.returnValue(b.constInt(42));
		var binding:IrDebugBinding = {identity: "checked", name: "checked", value: checked, path: "test.hx", scopeStart: 0, scopeEnd: 1};
		fn = new IrFunction("main", b.arguments, I32, b.blocks, Ordinary, [binding]);
		optimized = IrReceiverCheckElision.run(fn);
		expect(checks(optimized) == 1, "a debug-referenced check remains defined");

		b = new IrBuilder(); receiver = b.argument("receiver", Obj("Box")); var next = b.createBlock();
		check(b, receiver); b.blocks[0].instructions.push(new Located(EndTry(0, false), SourceProvenance.generated("test"))); b.jump(next);
		b.select(next); check(b, receiver); b.returnValue(b.constInt(42));
		fn = new IrFunction("main", b.arguments, I32, b.blocks, Ordinary);
		expect(checks(IrReceiverCheckElision.run(fn)) == 2, "handler-bearing functions do not propagate check facts across blocks");
		Sys.println("PASS: receiver checks preserve null failures across control flow");
	}
}
