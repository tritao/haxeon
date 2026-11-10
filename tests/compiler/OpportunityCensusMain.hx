import compiler.Frontend;
import compiler.ir.Ir;
import compiler.ir.IrFunction;
import compiler.ir.IrInliner;
import compiler.ir.IrBuilder;
import compiler.ir.IrInliner.IrInlineCache;
import compiler.ir.IrLoopBounds;
import compiler.ir.IrOpportunityCensus;
import compiler.ir.codec.IrFunctionStateCodec;

@:access(compiler.ir.IrOpportunityCensus)
class OpportunityCensusMain {
	static function expect(ok:Bool, message:String):Void {
		if (!ok)
			throw message;
	}

	static function main():Void {
		var source = 'class Box { public var value:Int; public function new() { value=7; } } function scan():Int { var b=new Box(); var sum=0; for(i in 0...10) sum+=b.value; return sum; } function main():Int return 0;';
		var program = Frontend.compile(source);
		IrInliner.run(program, new IrInlineCache(), compiler.ir.TargetProfile.wasm, true);
		var objects:Map<String, IrObject> = [];
		for (object in program.objects)
			objects.set(object.name, object);
		var fn:Null<IrFunction> = null;
		for (candidate in program.functions)
			if (candidate.name == "scan")
				fn = candidate;
		if (fn == null)
			throw "missing scan";
		var before = IrFunctionStateCodec.encode(fn),
			pure = IrLoopBounds.pureNativeCalls(program.natives);
		var row = IrOpportunityCensus.inspect(fn, pure, objects, true);
		expect(row.counts[5] == 1 && row.counts[6] == 1, "fresh ordinary object stays local");
		expect(row.allocations.length == 1 && row.allocations[0].local, "report allocation scope");
		expect(row.allocations[0].reason.indexOf("ordinary heap objects") >= 0, "explain scalar replacement exclusion");
		expect(row.counts[7] >= 1, "count a constant field in a loop");
		var instructions = 0, histogramTotal = 0, previous = "";
		for (block in fn.blocks) instructions += block.instructions.length;
		for (entry in row.histogram) {
			expect(previous < entry.opcode, "histogram is sorted and has unique opcodes");
			previous = entry.opcode;
			histogramTotal += entry.count;
		}
		expect(histogramTotal == instructions, "histogram accounts for every IR instruction");
		var b = new IrBuilder(), condition = b.constBool(true);
		b.constInt(123); // An unused definition, distinct from the branch's used condition.
		b.call("sideEffect", [], I32); // An unused result is not proof that its instruction is dead.
		var yes = b.createBlock(), no = b.createBlock(), bridge = b.createBlock(), exit = b.createBlock();
		b.branch(condition, yes, no);
		b.select(yes); b.jump(bridge);
		b.select(no); b.jump(exit);
		b.select(bridge); b.jump(exit);
		b.select(exit); b.returnValue(b.constInt(42));
		var flow = new IrFunction("flow", b.arguments, I32, b.blocks, None),
			flowRow = IrOpportunityCensus.inspect(flow, pure, objects, true);
		expect(flowRow.counts[9] == 2, "unused call results count even when the call may have side effects");
		expect(flowRow.counts[13] == 1, "pure unused results exclude side-effecting calls");
		expect(flowRow.counts[11] == 1, "count the constant branch");
		expect(flowRow.counts[12] == 1, "count the jump through an empty jump block");
		b = new IrBuilder();
		var fresh = b.newObject("Box"), unknown = b.argument("unknown", Obj("Box"));
		b.call(compiler.ir.IrReceiverCheck.NAME, [fresh], Void);
		b.call(compiler.ir.IrReceiverCheck.NAME, [unknown], Void);
		b.safeCast(fresh, Obj("Box"));
		b.safeCast(fresh, Dyn);
		b.returnValue(b.constInt(42));
		var checks = IrOpportunityCensus.inspect(new IrFunction("checks", b.arguments, I32, b.blocks, None), pure, objects, true);
		expect(checks.counts[14] == 1, "only a receiver check on a fresh value is counted");
		expect(checks.counts[15] == 1, "count casts with identical source and destination types");
		b = new IrBuilder(); unknown = b.argument("unknown", Obj("Box"));
		b.fieldSet(unknown, "value", b.constInt(1)); b.fieldSet(unknown, "value", b.constInt(2));
		b.fieldGet(unknown, "value", I32); b.fieldSet(unknown, "value", b.constInt(3));
		b.call("small", [], I32); b.returnValue(b.constInt(42));
		var stores = IrOpportunityCensus.inspect(new IrFunction("stores", b.arguments, I32, b.blocks, None), pure, objects, true, ["small" => true]);
		expect(stores.counts[16] == 1, "a field read stops the overwritten-store candidate scan");
		expect(stores.counts[17] == 1, "count direct calls to small known functions");
		expect(before.compare(IrFunctionStateCodec.encode(fn)) == 0, "diagnostics do not mutate IR");
		expect(IrOpportunityCensus.encodeRow(row) == IrOpportunityCensus.encodeRow(IrOpportunityCensus.inspect(fn, pure, objects, true)), "deterministic report");
		expect(haxe.Json.parse(IrOpportunityCensus.encodeRow(row)).name == fn.name, "stable row is valid JSON");
		expect(IrOpportunityCensus.isPowerOfTwo(2.0) && IrOpportunityCensus.isPowerOfTwo(-0.5), "signed normal powers");
		expect(IrOpportunityCensus.isPowerOfTwo(8.98846567431158e307), "large power excluded from strength reduction remains a power");
		expect(IrOpportunityCensus.isPowerOfTwo(5e-324), "subnormal power");
		expect(!IrOpportunityCensus.isPowerOfTwo(3.0) && !IrOpportunityCensus.isPowerOfTwo(0.0), "nonpowers and zero");
		expect(!IrOpportunityCensus.isPowerOfTwo(Math.NaN)
			&& !IrOpportunityCensus.isPowerOfTwo(Math.POSITIVE_INFINITY), "NaN and infinity");
		Sys.println("PASS: census explains allocations and counts constant fields without changing IR");
	}
}
