package compiler.backend.wasm;

import compiler.ir.tools.IrOpportunityCensus;

/** The Wasm part of the `IrOpportunityCensus`: what the module builders emitted. */
class WasmOpportunityCensus {
	/** Report the final Wasm instruction model; linked pre-encoded functions are explicitly marked opaque. */
	public static function report(module:WasmModule, target:String):Void {
		if (Sys.getEnv("HAXEON_IR_CENSUS") != "1")
			return;
		var segments = [
			for (segment in module.data)
				'{"category":'
				+ haxe.Json.stringify(segment.censusCategory == null ? "unclassified data" : segment.censusCategory)
				+ ',"bytes":'
				+ WasmEncoder.encodedDataSegmentLength(segment)
				+ '}'
		];
		Sys.stderr().writeString('SIZE_DATA_CENSUS {"target":' + haxe.Json.stringify(target) + ',"segments":['
			+ segments.join(",") + ']}\n');
		for (fn in module.functions) {
			var histogram:Map<String, Int> = [];
			for (op in fn.body)
				IrOpportunityCensus.addOpcode(histogram, IrOpportunityCensus.constructorName(Std.string(op)));
			Sys.stderr()
				.writeString("EMITTED_CENSUS {\"target\":"
				+ haxe.Json.stringify(target)
				+ ",\"name\":"
				+ haxe.Json.stringify(fn.name)
				+ ",\"instructions\":"
				+ fn.body.length
				+ ",\"opaqueBytes\":"
				+ (fn.encodedBody == null ? 0 : fn.encodedBody.length)
				+ ",\"bytes\":"
				+ WasmEncoder.encodeFunctionBody(fn).length
				+ ",\"histogram\":"
				+ IrOpportunityCensus.encodeHistogram(IrOpportunityCensus.sortedHistogram(histogram))
				+ "}\n");
		}
	}
}
