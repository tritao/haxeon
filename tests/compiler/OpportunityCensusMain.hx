import compiler.Frontend;
import compiler.ir.Ir;
import compiler.ir.IrFunction;
import compiler.ir.IrInliner;
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
		IrInliner.run(program, new IrInlineCache(), true);
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
		expect(before.compare(IrFunctionStateCodec.encode(fn)) == 0, "diagnostics do not mutate IR");
		expect(haxe.Json.stringify(row) == haxe.Json.stringify(IrOpportunityCensus.inspect(fn, pure, objects, true)), "deterministic report");
		expect(IrOpportunityCensus.isPowerOfTwo(2.0) && IrOpportunityCensus.isPowerOfTwo(-0.5), "signed normal powers");
		expect(IrOpportunityCensus.isPowerOfTwo(8.98846567431158e307), "large power excluded from strength reduction remains a power");
		expect(IrOpportunityCensus.isPowerOfTwo(5e-324), "subnormal power");
		expect(!IrOpportunityCensus.isPowerOfTwo(3.0) && !IrOpportunityCensus.isPowerOfTwo(0.0), "nonpowers and zero");
		expect(!IrOpportunityCensus.isPowerOfTwo(Math.NaN)
			&& !IrOpportunityCensus.isPowerOfTwo(Math.POSITIVE_INFINITY), "NaN and infinity");
		Sys.println("PASS: census explains allocations and counts constant fields without changing IR");
	}
}
