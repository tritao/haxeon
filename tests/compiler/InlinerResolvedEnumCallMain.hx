import compiler.ir.model.Ir;
import compiler.ir.model.IrBuilder;
import compiler.ir.model.IrFunction;
import compiler.ir.passes.inlining.IrInliner;
import compiler.ir.passes.inlining.IrInliner.IrInlineCache;
import compiler.ir.verify.IrVerifier;

/** A resolved enum boundary stays a call to its provider when an adapter is inlined. */
class InlinerResolvedEnumCallMain {
	static function main():Void {
		for (profile in [compiler.ir.pipeline.TargetProfile.hashLink, compiler.ir.pipeline.TargetProfile.wasm])
			for (box in [true, false]) {
				var program = new IrProgram("main");
				program.enums = [{name: "Choice", cases: [{name: "A", params: []}, {name: "B", params: []}]}];
				var tag:IrType = EnumTag("Choice"),
					inputType:IrType = box ? tag : Dyn,
					resultType:IrType = box ? Dyn : tag;
				program.natives = [
					{
						name: "provider_body",
						library: "test",
						symbol: "provider_body",
						arguments: [inputType],
						result: resultType
					}
				];
				var provider = new IrBuilder(),
					providerInput = provider.argument("value", inputType);
				var result = provider.call("provider_body", [providerInput], resultType);
				for (_ in 0...200)
					result = provider.call("provider_body", [providerInput], resultType);
				provider.returnValue(result);
				var adapter = new IrBuilder(),
					input = adapter.argument("value", inputType);
				adapter.returnValue(adapter.call("resolved_provider", [input], resultType));
				var caller = new IrBuilder(),
					callerInput = caller.argument("value", inputType);
				caller.returnValue(caller.call("adapter", [callerInput], resultType));
				program.functions = [
					new IrFunction("main", caller.arguments, resultType, caller.blocks, Ordinary),
					new IrFunction("adapter", adapter.arguments, resultType, adapter.blocks, GeneratedHelper, null,
						true),
					new IrFunction("resolved_provider", provider.arguments, resultType, provider.blocks,
						EnumTagAdapter(tag, box))
				];
				IrVerifier.verify(program);
				var cache = new IrInlineCache();
				IrInliner.run(program, cache, profile);
				IrVerifier.verify(program);
				IrInliner.run(program, cache, profile);
				IrVerifier.verify(program);
				var providerCalls = 0, adapterCalls = 0;
				for (block in program.functions[0].blocks)
					for (located in block.instructions)
						switch located.value {
							case Call(_, callTarget, _) if (callTarget.name == "adapter"):
								adapterCalls++;
							case Call(_, callTarget, arguments) if (callTarget.name == "resolved_provider"):
								providerCalls++;
								if (arguments.length != 1
									|| arguments[0].id != callerInput.id
									|| !IrVerifier.sameType(arguments[0].type, inputType))
									throw "Inlining changed the resolved enum provider operand";
							default:
						}
				if (adapterCalls != 0 || providerCalls != 1)
					throw 'Expected the inlined adapter to preserve one provider call, got $adapterCalls adapters and $providerCalls providers';
			}
		Sys.println("PASS: inlining preserves resolved enum provider calls");
	}
}
