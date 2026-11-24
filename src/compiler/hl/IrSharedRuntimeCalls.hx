package compiler.hl;

import compiler.ir.model.Ir.IrProgram;
import compiler.ir.model.Ir.IrType;
import compiler.ir.model.IrBodyBuilder;
import compiler.ir.model.IrBuilder;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrSymbol;
import compiler.ir.model.IrTypeIdentity;
import compiler.ir.model.IrTypeIds;
import compiler.ir.model.IrTypeMap;

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
		"__bytes_try_set" => true
	];

	public static inline final SUFFIX = "$shared:";

	public static function isHelper(name:String):Bool
		return name.indexOf(SUFFIX) > 0 && shared.exists(name.substr(0, name.indexOf(SUFFIX)));

	/**
	 * `program` with its runtime calls going through helpers, added after its own functions, and the helpers' names. With `memo`,
	 * a function whose IR is the object it was last time keeps the form it got then.
	 */
	public static function apply(program:IrProgram, ?memo:IrSharedCallsMemo):{program:IrProgram,
		helpers:Array<String>} {
		var helpers:Map<String, IrFunction> = [for (fn in program.functions) if (isHelper(fn.name)) fn.name => fn],
			added:Array<IrFunction> = [],
			madeBefore:Map<String, IrFunction> = memo == null ? [] : memo.helpers,
			made:Map<String, IrFunction> = [];
		// The helper of each runtime function by signature, so a call site whose helper is known spells no name.
		var named:Map<String, IrTypeMap<String>> = [];
		function helper(name:String, arguments:Array<IrType>, result:IrType):String {
			var signature = IrType.Function(arguments, result),
				bySignature = named.get(name);
			if (bySignature == null) {
				bySignature = new IrTypeMap();
				named.set(name, bySignature);
			}
			var known = bySignature.get(signature);
			if (known != null)
				return known;
			var key = name + SUFFIX + IrTypeIdentity.listText(arguments) + "->"
				+ IrTypeIdentity.text(result);
			bySignature.set(signature, key);
			if (!helpers.exists(key)) {
				// A helper is its key's alone, so the one made for it before is the same object: what is kept for it stays.
				var fn = madeBefore.get(key);
				if (fn == null) {
					var builder = new IrBuilder(),
						parameters = [for (index in 0...arguments.length) builder.argument("value" + index,
							arguments[index])];
					builder.returnValue(builder.call(name, parameters, result));
					fn = new IrFunction(key, builder.arguments, result, builder.blocks, GeneratedHelper);
				}
				made.set(key, fn);
				helpers.set(key, fn);
				added.push(fn);
			}
			return key;
		}
		// A helper's own call is the one that keeps the fast path.
		var result = program.copy(),
			types = IrTypeIds.ofFunctions(program.functions),
			builder = new IrBodyBuilder(types),
			rows:Array<Int> = [],
			targets:Array<Int> = [];
		result.functions = [];
		var known:Map<String, SharedCallsEntry> = memo == null ? [] : memo.entries,
			kept:Map<String, SharedCallsEntry> = [];
		for (fn in program.functions) {
			if (isHelper(fn.name)) {
				result.functions.push(fn);
				continue;
			}
			var entry = known.get(fn.name);
			if (entry != null && entry.source == fn) {
				for (call in entry.calls)
					helper(call.name, call.arguments, call.result);
				kept.set(fn.name, entry);
				result.functions.push(entry.result);
				continue;
			}
			// Frozen: a rewritten function shares its columns (`IrBody.withAuxes`).
			fn.bodyIn(types, builder);
			var body = fn.freezeBody(builder), calls:Array<SharedCall> = [];
			rows.resize(0);
			targets.resize(0);
			for (block in 0...body.blockCount()) {
				var row = body.firstRow(block);
				while (row >= 0) {
					if (body.opcode(row) == IrOpcode.Call && shared.exists(body.symbol(row).name)) {
						var call:SharedCall = {
							name: body.symbol(row).name,
							arguments: [for (operand in 0...body.operandCount(row)) body.valueType(body.operand(row,
								operand))],
							result: body.valueType(body.output(row))
						};
						calls.push(call);
						rows.push(row);
						targets.push(IrSymbol.of(helper(call.name, call.arguments, call.result)).id);
					}
					row = body.nextRow(row);
				}
			}
			var rewritten = rows.length == 0 ? fn : IrFunction.ofBody(body.withAuxes(rows, targets));
			kept.set(fn.name, {source: fn, result: rewritten, calls: calls});
			result.functions.push(rewritten);
		}
		if (memo != null) {
			memo.entries = kept;
			memo.helpers = made;
		}
		added.sort((left, right) -> left.name < right.name ? -1 : left.name > right.name ? 1 : 0);
		for (fn in added)
			result.functions.push(fn);
		return {program: result, helpers: [for (fn in added) fn.name]};
	}
}

/** A runtime call `IrSharedRuntimeCalls` sends through a helper: the runtime function, its argument types and its result. */
typedef SharedCall = {
	final name:String;
	final arguments:Array<IrType>;
	final result:IrType;
}

/** A function, its form with its runtime calls through helpers, and those calls. */
typedef SharedCallsEntry = {
	final source:IrFunction;
	final result:IrFunction;
	final calls:Array<SharedCall>;
}

/** Each function's form with its runtime calls through helpers, by name, kept while the function is the same object. */
class IrSharedCallsMemo {
	/** Replaced as a whole by each run (`IrSharedRuntimeCalls.apply`), never changed in place, so a copy shares it. */
	public var entries:Map<String, SharedCallsEntry> = [];

	/** The helpers the last run made, by name; replaced as a whole like `entries`. */
	public var helpers:Map<String, IrFunction> = [];

	public function new() {}

	public function copy():IrSharedCallsMemo {
		var result = new IrSharedCallsMemo();
		result.entries = entries;
		result.helpers = helpers;
		return result;
	}
}
