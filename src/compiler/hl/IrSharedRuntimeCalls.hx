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

	/** Whether `name` is a helper's: every runtime function it shares is named under `__`, as its helpers are. */
	public static function isHelper(name:String):Bool {
		if (name.length < 2 || StringTools.fastCodeAt(name, 0) != "_".code
			|| StringTools.fastCodeAt(name, 1) != "_".code)
			return false;
		var at = name.indexOf(SUFFIX);
		return at > 0 && shared.exists(name.substr(0, at));
	}

	/**
	 * `program` with its runtime calls going through helpers, added after its own functions, and the helpers' names. With `queries`,
	 * a function whose IR is the object it was last time keeps the form it got then, and a helper made before is that object again;
	 * with `checks`, a kept form is made again and compared.
	 */
	public static function apply(program:IrProgram, ?queries:compiler.hl.incremental.HlFunctionQueries,
			checks = false):{
				program:IrProgram,
				helpers:Array<String>
			} {
		var helpers:Map<String, IrFunction> = [for (fn in program.functions) if (isHelper(fn.name)) fn.name => fn],
			added:Array<IrFunction> = [];
		// The helper of each runtime function by signature id, so a call site whose helper is known spells no name.
		var named:Map<String, Map<Int, String>> = [];
		function helper(name:String, signature:Int):String {
			var bySignature = named.get(name);
			if (bySignature == null) {
				bySignature = [];
				named.set(name, bySignature);
			}
			var known = bySignature.get(signature);
			if (known != null)
				return known;
			var arguments:Array<IrType>, result:IrType;
			switch IrTypeIds.type(signature) {
				case Function(parameters, returned):
					arguments = parameters;
					result = returned;
				default:
					throw new compiler.core.InternalError('runtime call $name has no function signature');
			}
			var key = name + SUFFIX + IrTypeIdentity.listText(arguments) + "->"
				+ IrTypeIdentity.text(result);
			bySignature.set(signature, key);
			if (!helpers.exists(key)) {
				// A helper is its key's alone, so the one made for it before is the same object: what is kept for it stays.
				var symbol = IrSymbol.of(key).functionKey(),
					fn = queries == null ? null : queries.sharedHelpers.kept(symbol);
				if (fn == null) {
					var builder = new IrBuilder(),
						parameters = [for (index in 0...arguments.length) builder.argument("value" + index,
							arguments[index])];
					builder.returnValue(builder.call(name, parameters, result));
					fn = new IrFunction(key, builder.arguments, result, builder.blocks, GeneratedHelper);
				}
				if (queries != null)
					fn = queries.sharedHelpers.put(queries.database, symbol, fn);
				helpers.set(key, fn);
				added.push(fn);
			}
			return key;
		}
		// A helper's own call is the one that keeps the fast path.
		var result = program.copy(),
			builder = new IrBodyBuilder(),
			rows:Array<Int> = [],
			targets:Array<Int> = [];
		result.functions = [];
		for (fn in program.functions) {
			if (isHelper(fn.name)) {
				result.functions.push(fn);
				continue;
			}
			var kept = queries == null ? null : queries.sharedCalls.of(fn);
			if (kept != null && !checks) {
				for (call in kept.calls)
					helper(call.name, call.signature);
				result.functions.push(kept.result ?? fn);
				continue;
			}
			// Frozen: a rewritten function shares its columns (`IrBody.withAuxes`).
			fn.encodedBody(builder);
			var body = fn.freezeBody(builder), calls:Array<SharedCall> = [];
			rows.resize(0);
			targets.resize(0);
			for (block in 0...body.blockCount()) {
				var row = body.firstRow(block);
				while (row >= 0) {
					if (body.opcode(row) == IrOpcode.Call && shared.exists(body.symbol(row).name)) {
						var call:SharedCall = {
							name: body.symbol(row).name,
							signature: IrTypeIds.id(IrType.Function([
								for (operand in 0...body.operandCount(row)) body.valueType(body.operand(row, operand))
							], body.valueType(body.output(row))))
						};
						calls.push(call);
						rows.push(row);
						targets.push(IrSymbol.of(helper(call.name, call.signature)).id);
					}
					row = body.nextRow(row);
				}
			}
			var made = rows.length == 0
				? SharedCalls.NONE : new SharedCalls(IrFunction.ofBody(body.withAuxes(rows, targets)),
				calls);
			if (kept != null) {
				if (!SharedCalls.same(kept, made))
					throw new compiler.core
						.InternalError('--check-reuse: the shared runtime calls kept for ${fn.name} differ from its body');
				made = kept;
			} else if (queries != null)
				made = queries.sharedCalls.keep(fn, made);
			result.functions.push(made.result ?? fn);
		}
		added.sort((left, right) -> left.name < right.name ? -1 : left.name > right.name ? 1 : 0);
		for (fn in added)
			result.functions.push(fn);
		return {program: result, helpers: [for (fn in added) fn.name]};
	}
}

/** A runtime call `IrSharedRuntimeCalls` sends through a helper: the runtime function and the id of its function type. */
typedef SharedCall = {
	final name:String;
	final signature:Int;
}

/** A function's form with its runtime calls through helpers, and those calls; `NONE` for a function that makes none. */
class SharedCalls {
	@:processWide("the form of a function that makes no shared runtime call: the function itself, never changed")
	public static final NONE = new SharedCalls(null, []);

	/** The rewritten function; null for the function itself. */
	public final result:Null<IrFunction>;

	public final calls:Array<SharedCall>;

	public function new(result:Null<IrFunction>, calls:Array<SharedCall>) {
		this.result = result;
		this.calls = calls;
	}

	/** Whether two forms of one function make the same calls and have the same IR (`--check-reuse`). */
	public static function same(left:SharedCalls, right:SharedCalls):Bool {
		if (left == right)
			return true;
		if (left.calls.length != right.calls.length)
			return false;
		for (index in 0...left.calls.length)
			if (left.calls[index].name != right.calls[index].name
				|| left.calls[index].signature != right.calls[index].signature)
				return false;
		var a = left.result, b = right.result;
		return a == b || a != null && b != null && compiler.ir.codec.IrFunctionStateEquality.same(a, b);
	}
}
