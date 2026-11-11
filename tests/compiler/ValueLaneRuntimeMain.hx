import compiler.ir.IrValueLaneRuntime;
import compiler.ir.Ir;
import compiler.ir.IrFunction;
import compiler.ir.IrValueLaneLayout.IrValueLaneTarget;
import compiler.runtime.ValueLaneNativeSource;
import sys.io.File;

/** Native and Wasm policy cannot silently diverge when the portable SSA changes. */
class ValueLaneRuntimeMain {
	static function main():Void {
		IrValueLaneRuntime.program(); // Includes full SSA and native signature verification.
		IrValueLaneRuntime.program(false);
		var expected = ValueLaneNativeSource.generate();
		if (expected != File.getContent("native/runtime/value_lane_policy.h"))
			throw "Regenerate native/runtime/value_lane_policy.h with compiler.tools.GenerateValueLaneRuntime";
		if (expected != ValueLaneNativeSource.generate()) throw "Lane policy generation must be deterministic";
		// Absent optional payloads must clear their storage without inventing a null type handle.
		var handle:IrObject = {name:"OptionalHandle", isValue:true, base:null, interfaces:[], methods:[], fields:[{name:"type", type:TypeRef}]};
		for (target in ([HashLink, Wasm32, WasmGc]:Array<IrValueLaneTarget>)) {
			var factory = new compiler.ir.IrValueArrayFactory(compiler.ir.IrObjectTable.of([handle.name => handle]), Nullable(Obj(handle.name)), target == HashLink ? 64 : 32, target),
				program = new IrProgram("main"), body = new compiler.ir.IrBuilder();
			body.returnValue(body.constInt(42)); program.objects = [handle];
			program.functions = [new IrFunction("main", body.arguments, I32, body.blocks, None, [])].concat(factory.functions()).concat(factory.helpers.functions());
			program.natives = factory.natives().concat(factory.helpers.natives());
			compiler.ir.IrVerifier.verify(program);
		}
		Sys.println("PASS: portable lane policy verifies and its native C artifact is current and deterministic");
	}
}
