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
 * is expanded as the inliner expands a call (`IrBodyCallExpansion`).
 */
class IrValueArrayScalarLowering {
	/**
	 * Expands the calls of `element`'s boundary helpers in `program`'s functions, whose bodies are `types`'s: only in those `scope`
	 * names when given, the only ones that can call them. A function that changes becomes its edited body, edited in place when the
	 * stage owns it, else on a copy.
	 */
	public static function rewrite(program:IrProgram, element:IrType, expandAll:Bool, types:IrTypeIds,
			scratch:IrPassScratch, ?scope:Map<String, Bool>):Void {
		var builder = scratch.bodyBuilder;
		// The helpers as they are before any expansion: a helper's own body may be expanded in place below.
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
		var functions = program.functions;
		for (index in 0...functions.length) {
			var fn = functions[index];
			if (scope != null && !scope.exists(fn.name))
				continue;
			var body = fn.bodyIn(types, builder),
				edited = rewriteBody(body, helpers, scratch);
			if (edited != body)
				functions[index] = IrFunction.ofOwnedBody(edited);
		}
	}

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
