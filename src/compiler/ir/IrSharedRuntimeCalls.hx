package compiler.ir;

import compiler.ir.Ir.IrInstruction;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.ir.Ir.IrValue;
import compiler.ir.SourceProvenance.Located;

/**
 * On HashLink the lowering writes a fast path in place of a call to some runtime functions (an array push, a byte read or write; see
 * `HlLower.lowerRuntimeFastPath`): a dozen instructions where stock Haxe writes one call, at every call site. HashLink compiles every
 * instruction of a module when it loads it, so that is start-up time paid for each site. Here each such call, but the one in its
 * helper, goes through one helper per runtime function and signature, whose body is the call: the fast path is written once, in the
 * helper, and a call site is one call into compiled code, cheaper than the native call the slow path makes.
 *
 * It is a HashLink lowering decision, so the HashLink module assembler applies it to its own copy of the final IR (`HlModuleAssembler`):
 * the IR every backend shares keeps the runtime calls. The helpers are named under `__`, which the inliner would never inline.
 */
class IrSharedRuntimeCalls {
	/** The runtime functions the HashLink lowering writes a fast path for. */
	static final shared:Map<String, Bool> = [
		"__array_push_i32" => true,
		"__array_push_i64" => true,
		"__array_push_f64" => true,
		"__array_push_bool" => true,
		"__array_push_bytes" => true,
		"__array_push_ref" => true,
		"__bytes_get" => true,
		"__bytes_set" => true
	];

	public static inline final SUFFIX = "$shared:";

	public static function isHelper(name:String):Bool
		return name.indexOf(SUFFIX) > 0 && shared.exists(name.substr(0, name.indexOf(SUFFIX)));

	/** `program` with its runtime calls going through helpers, added after its own functions, and the helpers' names. */
	public static function apply(program:IrProgram):{program:IrProgram, helpers:Array<String>} {
		var helpers:Map<String, IrFunction> = [for (fn in program.functions) if (isHelper(fn.name)) fn.name => fn],
			added:Array<IrFunction> = [];
		function helper(name:String, arguments:Array<IrValue>, result:IrType):String {
			var key = name + SUFFIX + IrTypeIdentity.listText([for (argument in arguments) argument.type]) + "->"
				+ IrTypeIdentity.text(result);
			if (!helpers.exists(key)) {
				var builder = new IrBuilder(),
					parameters = [for (index in 0...arguments.length) builder.argument("value" + index,
						arguments[index].type)];
				builder.returnValue(builder.call(name, parameters, result));
				var fn = new IrFunction(key, builder.arguments, result, builder.blocks, GeneratedHelper);
				helpers.set(key, fn);
				added.push(fn);
			}
			return key;
		}
		// A helper's own call is the one that keeps the fast path.
		var result = program.copy();
		result.functions = [for (fn in program.functions)
			isHelper(fn.name) ? fn : IrFunctionRewrite.instructions(fn, located -> switch located.value {
				case Call(output, name, arguments) if (shared.exists(name)):
					[new Located(IrInstruction.Call(output, helper(name, arguments, output.type), arguments),
						located.provenance)];
				default: null;
			})];
		added.sort((left, right) -> left.name < right.name ? -1 : left.name > right.name ? 1 : 0);
		for (fn in added)
			result.functions.push(fn);
		return {program: result, helpers: [for (fn in added) fn.name]};
	}
}
