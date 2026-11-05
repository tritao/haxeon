import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrNonNullFacts;
import compiler.ir.IrReceiverCheck;
import compiler.ir.SourceProvenance;
import compiler.ir.SourceProvenance.Located;

class NonNullFactsMain {
	static function expect(value:Bool, message:String):Void if (!value) throw message;
	static function check(b:IrBuilder, receiver:IrValue):{block:Int, index:Int} {
		b.call(IrReceiverCheck.NAME, [receiver], Void);
		return {block: b.currentBlock().id, index: b.currentBlock().instructions.length - 1};
	}
	static function main():Void {
		var b = new IrBuilder(), receiver = b.argument("receiver", Obj("Box"));
		var unknown = check(b, receiver), repeated = check(b, receiver), fresh = b.newObject("Box"), allocated = check(b, fresh);
		b.returnValue(b.constInt(42));
		var facts = new IrNonNullFacts(new IrFunction("fresh", b.arguments, I32, b.blocks));
		expect(!facts.has(unknown.block, unknown.index) && facts.has(repeated.block, repeated.index) && facts.has(allocated.block, allocated.index), "fresh and successful checks");

		b = new IrBuilder(); receiver = b.argument("receiver", Obj("Box"));
		var yes = b.createBlock(), no = b.createBlock(), join = b.createBlock();
		b.branch(b.equal(receiver, b.constNull(Obj("Box"))), yes, no);
		b.select(yes); b.jump(join);
		b.select(no); var nonnull = check(b, receiver); b.jump(join);
		b.select(join); var merged = check(b, receiver); b.returnValue(b.constInt(42));
		facts = new IrNonNullFacts(new IrFunction("branch", b.arguments, I32, b.blocks));
		expect(facts.has(nonnull.block, nonnull.index) && !facts.has(merged.block, merged.index), "only the non-null branch establishes a fact");

		for (pre in [false, true]) {
			b = new IrBuilder(); receiver = b.argument("receiver", Obj("Box")); var condition = b.argument("condition", Bool);
			var header = b.createBlock(), body = b.createBlock(), exit = b.createBlock();
			if (pre) check(b, receiver);
			b.jump(header); b.select(header); b.branch(condition, body, exit);
			b.select(body); var inside = check(b, receiver); b.jump(header);
			b.select(exit); var after = check(b, receiver); b.returnValue(b.constInt(42));
			facts = new IrNonNullFacts(new IrFunction("loop", b.arguments, I32, b.blocks));
			expect(facts.has(inside.block, inside.index) == pre && facts.has(after.block, after.index) == pre, "loop facts must hold before the first iteration");
		}


		for (bothFresh in [false, true]) {
			b = new IrBuilder(); var condition = b.argument("condition", Bool), maybe = b.argument("maybe", Obj("Box"));
			yes = b.createBlock(); no = b.createBlock(); join = b.createBlock(); b.branch(condition, yes, no);
			b.select(yes); var left = b.newObject("Box"); b.jump(join);
			b.select(no); var right = bothFresh ? b.newObject("Box") : maybe; b.jump(join);
			b.select(join); var value = b.phi(Obj("Box"), [{block: yes.id, value: left}, {block: no.id, value: right}]);
			var phiCheck = check(b, value); b.returnValue(b.constInt(42));
			facts = new IrNonNullFacts(new IrFunction("phi", b.arguments, I32, b.blocks));
			expect(facts.has(phiCheck.block, phiCheck.index) == bothFresh, "phi requires a non-null value on every incoming edge");
		}

		b = new IrBuilder(); receiver = b.argument("receiver", Obj("Box"));
		b.fieldGet(receiver, "value", I32); var afterField = check(b, receiver); b.returnValue(b.constInt(42));
		var fn = new IrFunction("field", b.arguments, I32, b.blocks);
		expect(!new IrNonNullFacts(fn).has(afterField.block, afterField.index) && new IrNonNullFacts(fn, true).has(afterField.block, afterField.index),
			"only targets that check dereferences can use that fact");

		b = new IrBuilder(); receiver = b.argument("receiver", Obj("Box")); var next = b.createBlock();
		check(b, receiver); b.currentBlock().instructions.push(new Located(EndTry(0, false), SourceProvenance.generated("test"))); b.jump(next);
		b.select(next); var handler = check(b, receiver); b.returnValue(b.constInt(42));
		facts = new IrNonNullFacts(new IrFunction("handler", b.arguments, I32, b.blocks));
		expect(!facts.has(handler.block, handler.index), "exception regions prevent cross-block propagation");

		b = new IrBuilder(); var allocatedValue = b.newObject("Box"), later = b.createBlock();
		b.currentBlock().instructions.push(new Located(EndTry(0, false), SourceProvenance.generated("test"))); b.jump(later);
		b.select(later); var freshInHandler = check(b, allocatedValue); b.returnValue(b.constInt(42));
		facts = new IrNonNullFacts(new IrFunction("freshHandler", b.arguments, I32, b.blocks));
		expect(facts.has(freshInHandler.block, freshInHandler.index), "fresh SSA values remain non-null across exception regions");

		b = new IrBuilder(); receiver = b.argument("receiver", Obj("Box"));
		var first = b.fieldGet(receiver, "a", I32), second = b.fieldGet(receiver, "b", I32);
		b.returnValue(b.add(first, second));
		var program = new IrProgram("main");
		program.functions = [new IrFunction("main", b.arguments, I32, b.blocks)];
		program.objects = [{name: "Box", isValue: false, base: null, interfaces: [],
			fields: [{name: "a", type: I32}, {name: "b", type: I32}], methods: []}];
		var checks = 0;
		for (function_ in compiler.ir.hl.HlLower.lower(program).functions) for (opcode in function_.opcodes) switch opcode {
			case NullCheck(_): checks++;
			default:
		}
		expect(checks == 1, "HashLink keeps the first null check and omits the repeated field check");
		Sys.println("PASS: non-null facts respect branches, loops, allocation and handlers");
	}
}
