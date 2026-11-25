package compiler.hl;

import compiler.ir.tools.IrOpportunityCensus;

/** The HashLink part of the `IrOpportunityCensus`: what lowering emitted. */
class HlOpportunityCensus {
	/**
	 * Report the actual lowered HashLink operations, after register allocation, and the sizes of the module's parts: of `sections`
	 * when the build writes module sections, else of `code` as HlWriter writes it.
	 */
	public static function report(code:HlCode, indices:Map<String, Int>, ?sections:haxeon.io.SegmentedBytes):Void {
		if (Sys.getEnv("HAXEON_IR_CENSUS") != "1")
			return;
		if (sections == null)
			HlWriter.reportSize(code);
		else
			reportSectionSizes(sections.flatten());
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

	/** The parts of a module of sections, summed over its sections (`HlStaticLink.linkWithParts`); the header counts the magic. */
	static function reportSectionSizes(bytes:haxe.io.Bytes):Void {
		var parts = HlStaticLink.linkWithParts(bytes).parts;
		var fields = [
			for (index in 0...parts.length)
				haxe.Json.stringify(parts[index].name) + ":" + (parts[index].bytes + (index == 0 ? 4 : 0))
		];
		Sys.stderr()
			.writeString('SIZE_CENSUS {"target":"hl",' + fields.join(",")
			+ ',"sections":[],"topTypes":[],"topStrings":[],"topStringUses":[],"topFunctionDebug":[]}\n');
	}
}
