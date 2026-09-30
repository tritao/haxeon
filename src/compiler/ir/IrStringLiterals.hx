package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.SourceProvenance.Located;

/**
 * A string literal allocates a fresh String object every time it is evaluated: a patch cannot add a global to hold one, so
 * the object is built over the module's interned UTF-16 data at each use. A literal evaluated in a loop, or repeated along
 * one path, therefore allocates over and over.
 *
 * This pass evaluates each literal once per call. The single definition goes to the nearest block that dominates every
 * place the literal was defined, or to the entry block when that block runs more than once per call (it sits in a loop).
 * Strings are immutable, so sharing one object is unobservable. A literal defined once outside any loop is left where it is,
 * so a path that never reaches it still allocates nothing.
 */
class IrStringLiterals {
	/**
	 * The message of the throw the generator puts after a call that never returns. It is cold, and hoisting it out of that block makes
	 * the Wasm GC lowering, which drops the code after such a call, emit a function that underflows the value stack.
	 */
	static inline var UnreachableMessage = "Reached compiler-generated unreachable block";

	public static function hoist(fn:IrFunction):IrFunction {
		var graph:IrGraph;
		try
			graph = new IrGraph(fn)
		catch (_:Dynamic)
			return fn;
		var definitions:Map<String, Array<{block:Int, output:IrValue, provenance:SourceProvenance}>> = [];
		var order:Array<String> = [];
		for (id in graph.order)
			for (located in graph.block(id).instructions)
				switch located.value {
					case ConstString(output, value):
						if (!definitions.exists(value)) {
							definitions.set(value, []);
							order.push(value);
						}
						definitions.get(value).push({block: id, output: output, provenance: located.provenance});
					default:
				}
		var substitutions:Map<Int, IrValue> = [];
		var removed:Map<Int, Bool> = [];
		var inserted:Map<Int, Array<Located<IrInstruction>>> = [];
		var loops:Map<Int, Bool> = [];
		for (literal in order) {
			if (literal == UnreachableMessage)
				continue;
			var defs = definitions.get(literal);
			var target = defs[0].block;
			for (index in 1...defs.length)
				while (!graph.dominates(target, defs[index].block))
					target = graph.immediate.get(target);
			if (!loops.exists(target))
				loops.set(target, inLoop(graph, target));
			var looped = loops.get(target);
			if (defs.length == 1 && !looped)
				continue;
			if (looped)
				target = graph.order[0];
			var canonical = defs[0].output;
			for (definition in defs) {
				removed.set(definition.output.id, true);
				if (definition.output.id != canonical.id)
					substitutions.set(definition.output.id, canonical);
			}
			if (!inserted.exists(target))
				inserted.set(target, []);
			inserted.get(target).push(new Located(ConstString(canonical, literal), defs[0].provenance));
		}
		if (order.length == 0 || !anyChange(removed))
			return fn;
		var use = function(value:IrValue):IrValue {
			var replacement = substitutions.get(value.id);
			return replacement == null ? value : replacement;
		};
		var sameBlock = function(id:Int):Int return id;
		for (block in fn.blocks) {
			var kept:Array<Located<IrInstruction>> = [];
			var leadingPhis:Array<Located<IrInstruction>> = [];
			var phisDone = false;
			for (located in block.instructions) {
				switch located.value {
					case ConstString(output, _) if (removed.exists(output.id)):
						continue;
					default:
				}
				var rewritten = new Located(IrInliner.remap(located.value, use, sameBlock), located.provenance);
				if (!phisDone)
					switch rewritten.value {
						case Phi(_, _):
							leadingPhis.push(rewritten);
							continue;
						default:
							phisDone = true;
					}
				kept.push(rewritten);
			}
			var additions = inserted.get(block.id);
			block.instructions.resize(0);
			for (phi in leadingPhis)
				block.instructions.push(phi);
			if (additions != null)
				for (addition in additions)
					block.instructions.push(addition);
			for (instruction in kept)
				block.instructions.push(instruction);
			var terminator = block.terminator;
			if (terminator != null)
				block.terminator = new Located(switch terminator.value {
					case Return(value): Return(use(value));
					case Throw(value): Throw(use(value));
					case Rethrow(value): Rethrow(use(value));
					case Jump(target): Jump(target);
					case Branch(condition, whenTrue, whenFalse): Branch(use(condition), whenTrue, whenFalse);
				}, terminator.provenance);
		}
		var bindings = [
			for (binding in fn.debugBindings)
				{
					identity: binding.identity,
					name: binding.name,
					value: use(binding.value),
					path: binding.path,
					scopeStart: binding.scopeStart,
					scopeEnd: binding.scopeEnd
				}
		];
		return new IrFunction(fn.name, fn.arguments, fn.result, fn.blocks, bindings, fn.inlineHint);
	}

	static function anyChange(removed:Map<Int, Bool>):Bool {
		for (_ in removed.keys())
			return true;
		return false;
	}

	/** Whether `id` can reach itself again, that is, whether it runs more than once per call. */
	static function inLoop(graph:IrGraph, id:Int):Bool {
		var seen:Map<Int, Bool> = [], work:Array<Int> = [];
		for (successor in graph.successors.get(id))
			work.push(successor);
		while (work.length > 0) {
			var current = work.pop();
			if (current == id)
				return true;
			if (seen.exists(current))
				continue;
			seen.set(current, true);
			for (successor in graph.successors.get(current))
				work.push(successor);
		}
		return false;
	}
}
