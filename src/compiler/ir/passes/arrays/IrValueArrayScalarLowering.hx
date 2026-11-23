package compiler.ir.passes.arrays;

import compiler.ir.model.Ir;
import compiler.ir.model.IrBody;
import compiler.ir.model.IrBodyBuilder;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrPassScratch;
import compiler.ir.model.IrTypeIds;

/**
 * Expand compiler-generated array element boundaries before scalar replacement on every target, on bodies: each call of a helper
 * is expanded as the inliner expands a call (`IrBodyCallExpansion`). Per function (`IrFunctionPass`): a function that calls a
 * helper of the element reads, for each, the version the helper had as the stage started (`HELPER`), so it is expanded again
 * only when it or a helper it calls changed.
 */
@:nullSafety(Strict)
class IrValueArrayScalarLowering implements compiler.ir.pipeline.IrFunctionPass {
	static inline final HELPER = 0;

	/** A function's summary: it calls a function named as one of the element's helpers. */
	static inline final CALLS = 1;

	final prefix = IrValueArrayElements.PREFIX;
	final suffix:String;
	final helpers:Map<String, IrBody>;
	final types:IrTypeIds;
	final scratch:IrPassScratch;
	final lineage:Null<compiler.ir.reuse.IrStageMemo.IrLineage>;
	final versions:Map<String, Int> = [];

	function new(suffix:String, helpers:Map<String, IrBody>, types:IrTypeIds, scratch:IrPassScratch,
			lineage:Null<compiler.ir.reuse.IrStageMemo.IrLineage>) {
		this.suffix = suffix;
		this.helpers = helpers;
		this.types = types;
		this.scratch = scratch;
		this.lineage = lineage;
	}

	/**
	 * Expands the calls of `element`'s boundary helpers in `program`'s functions, whose bodies are `types`'s; in a session with
	 * `lineage`, reusing what it made of each function whose version and helpers are unchanged. A function that changes becomes
	 * its edited body, edited in place when the stage owns it, else on a copy.
	 */
	public static function rewrite(program:IrProgram, element:IrType, expandAll:Bool, types:IrTypeIds,
			scratch:IrPassScratch, ?lineage:compiler.ir.reuse.IrStageMemo.IrLineage):Void {
		var builder = scratch.bodyBuilder;
		// The helpers as they are before any expansion: a helper's own body may be expanded below.
		var helpers:Map<String, IrBody> = [];
		var suffix = ":" + haxe.crypto.Base64.encode(compiler.ir.codec.IrTypeCodec.encode(element));
		for (fn in program.functions)
			if (StringTools.startsWith(fn.name, IrValueArrayElements.PREFIX)
				&& StringTools.endsWith(fn.name, suffix)
				&& (expandAll
				|| StringTools.startsWith(fn.name, IrValueArrayElements.PREFIX + "optional-")
				|| StringTools.startsWith(fn.name, IrValueArrayElements.PREFIX + "iterator-next:"))) {
				var body = fn.bodyIn(types, builder);
				helpers.set(fn.name, body.frozen ? body : IrBodyBuilder.copy(body, builder));
			}
		if (!helpers.keys().hasNext())
			return;
		program.functions = compiler.ir.pipeline.IrFunctionStages.run("value-array-scalar:"
			+ compiler.ir.model.IrTypeIdentity.text(element),
			new IrValueArrayScalarLowering(suffix, helpers, types, scratch, lineage), program.functions, lineage,
			lineage != null && lineage.checks, builder);
	}

	/** Whether `name` is named as one of the element's helpers, expanded or not. */
	inline function helperName(name:String):Bool
		return StringTools.startsWith(name, prefix) && StringTools.endsWith(name, suffix);

	public function summarize(fn:IrFunction):Int {
		var body = fn.bodyIn(types, scratch.bodyBuilder);
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				if (body.opcode(row) == IrOpcode.Call && helperName(body.symbol(row).name))
					return CALLS;
				row = body.nextRow(row);
			}
		}
		return 0;
	}

	public function prepare(functions:Array<IrFunction>, summaries:Array<Int>,
			names:compiler.ir.pipeline.IrFunctionIndex):Void {
		var known = lineage;
		if (known != null)
			for (name in helpers.keys())
				versions.set(name, known.version(name));
	}

	public function fact(kind:Int, key:String):Int
		return helpers.exists(key) ? versions.get(key) ?? 0 : -1;

	public function transform(fn:IrFunction, summary:Int, reader:compiler.ir.reuse.IrFactReader):IrFunction {
		if (summary != CALLS)
			return fn;
		var body = fn.bodyIn(types, scratch.bodyBuilder);
		if (reader.records())
			for (block in 0...body.blockCount()) {
				var row = body.firstRow(block);
				while (row >= 0) {
					if (body.opcode(row) == IrOpcode.Call && helperName(body.symbol(row).name))
						reader.read(HELPER, body.symbol(row).name);
					row = body.nextRow(row);
				}
			}
		var edited = rewriteBody(body, helpers, scratch);
		return edited == body ? fn : IrFunction.ofOwnedBody(edited);
	}

	public function request(kind:Int, type:IrType, name:Null<String>):Void
		throw new compiler.core.InternalError("The value array scalar lowering asks for no helper");

	public function finish(functions:Array<IrFunction>):Array<IrFunction>
		return functions;

	/** A call row of `body` to one of `helpers` other than itself, with as many operands as it takes arguments: the helper. */
	static function helperCall(body:IrBody, row:Int, helpers:Map<String, IrBody>):Null<IrBody> {
		if (body.opcode(row) != IrOpcode.Call)
			return null;
		var name = body.symbol(row).name;
		if (name == body.name)
			return null;
		var helper = helpers.get(name);
		return helper != null && helper.argumentCount() == body.operandCount(row) ? helper : null;
	}

	/** `body` with every helper call expanded: on `body` itself when no cache holds it, else on a copy; `body` when there is none. */
	static function rewriteBody(body:IrBody, helpers:Map<String, IrBody>, scratch:IrPassScratch):IrBody {
		var found = false;
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0 && !found) {
				if (helperCall(body, row, helpers) != null)
					found = true;
				row = body.nextRow(row);
			}
			if (found)
				break;
		}
		if (!found)
			return body;
		var edited = body.forEditing(scratch.bodyBuilder), nextBlock = 0;
		for (block in 0...edited.blockCount())
			if (edited.blockId(block) >= nextBlock)
				nextBlock = edited.blockId(block) + 1;
		var index = 0;
		while (index < edited.blockCount()) {
			var call = -1, callee:Null<IrBody> = null, row = edited.firstRow(index);
			while (row >= 0) {
				callee = helperCall(edited, row, helpers);
				if (callee != null) {
					call = row;
					break;
				}
				row = edited.nextRow(row);
			}
			if (callee != null)
				nextBlock = scratch.callExpansion.expand(edited, index, call, callee, nextBlock, false);
			// Scan the cloned body too: push and insert helpers call the element setter.
			index++;
		}
		return edited;
	}
}
