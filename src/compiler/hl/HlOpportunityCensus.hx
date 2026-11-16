package compiler.hl;

import compiler.ir.IrOpportunityCensus;

/** The HashLink part of the `IrOpportunityCensus`: what lowering emitted. */
class HlOpportunityCensus {
	/** Report the actual lowered HashLink operations, after register allocation. */
	public static function report(code:HlCode, indices:Map<String, Int>):Void {
		if (Sys.getEnv("HAXEON_IR_CENSUS") != "1")
			return;
		HlWriter.reportSize(code);
		var names:Map<Int, String> = [];
		for (name => index in indices)
			names.set(index, name);
		var functions = code.functions.copy();
		functions.sort((a, b) -> a.functionIndex - b.functionIndex);
		for (fn in functions) {
			var histogram:Map<String, Int> = [];
			for (op in fn.opcodes)
				IrOpportunityCensus.addOpcode(histogram, IrOpportunityCensus.constructorName(Std.string(op)));
			var name = names.get(fn.functionIndex);
			Sys.stderr()
				.writeString("EMITTED_CENSUS {\"target\":\"hl\",\"name\":"
				+ haxe.Json.stringify(name == null ? "#" + fn.functionIndex : name)
				+ ",\"index\":"
				+ fn.functionIndex
				+ ",\"instructions\":"
				+ fn.opcodes.length
				+ ",\"bytes\":"
				+ HlWriter.encodeFunction(fn).length
				+ ",\"histogram\":"
				+ IrOpportunityCensus.encodeHistogram(IrOpportunityCensus.sortedHistogram(histogram))
				+ "}\n");
		}
	}
}
