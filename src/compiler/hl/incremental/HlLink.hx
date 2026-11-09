package compiler.hl.incremental;

import compiler.hl.HlFunction;
import compiler.hl.HlFunction.HlInstruction;
import compiler.hl.incremental.HlSymbolRequest.HlRemap;
import compiler.ir.hl.HlLoweringView;

/** A lowered function given the indices of a build, or the reason it cannot have them. */
typedef HlLinked = {
	final fn:Null<HlFunction>;
	final reason:Null<String>;
}

/**
 * The link step for lowered functions: gives a function that was lowered against one set of tables and one function layout the
 * indices of another, without lowering it again. It checks the facts the function read about object types, replays its requests
 * against the new tables (which also makes the tables what lowering the functions in order would have made them), and rewrites the
 * constant, type, global and function indices in its code, registers and debug names. A function whose indices all stay is returned
 * as it is, so the encoding cached for it stays valid.
 */
class HlLink {
	public static function link(lowered:HlLoweredFunction, symbols:HlSymbolTable, functions:Map<String, Int>, view:HlLoweringView):HlLinked {
		var stale = view.holds(lowered.facts);
		if (stale != null)
			return {fn: null, reason: 'fact $stale changed'};
		var remap = new HlRemap();
		for (request in lowered.requests) {
			var reason = remap.replay(request, symbols, functions);
			if (reason != null)
				return {fn: null, reason: reason};
		}
		var own = functions.get(lowered.name);
		if (own == null)
			return {fn: null, reason: 'function ${lowered.name} is not in the layout'};
		var before = lowered.fn;
		if (remap.identity && own == before.functionIndex)
			return {fn: before, reason: null};
		return {
			fn: new HlFunction(index(remap.types, before.type, "function type"), own,
				[for (register in before.registers) index(remap.types, register, "register type")],
				[for (instruction in before.opcodes) rewrite(instruction, remap)], before.debugLocations, [
					for (assignment in before.debugAssignments)
						{name: index(remap.strings, assignment.name, "debug name"), position: assignment.position, scopeEnd: assignment.scopeEnd}
				]),
			reason: null
		};
	}

	/** An index the function uses must be one of its requests: anything else would be moved by no one. */
	static function index(map:Map<Int, Int>, from:Int, what:String):Int {
		var to = map.get(from);
		if (to == null)
			throw 'HashLink link: $what index $from was not requested while the function was lowered';
		return to;
	}

	static function rewrite(instruction:HlInstruction, remap:HlRemap):HlInstruction
		return switch instruction {
			case LoadInt(destination, constant): LoadInt(destination, index(remap.ints, constant, "integer constant"));
			case LoadFloat(destination, constant): LoadFloat(destination, index(remap.floats, constant, "float constant"));
			case LoadString(destination, constant): LoadString(destination, index(remap.strings, constant, "string"));
			case LoadType(destination, type): LoadType(destination, index(remap.types, type, "type"));
			case GlobalGet(destination, global): GlobalGet(destination, index(remap.globals, global, "global"));
			case GlobalSet(global, source): GlobalSet(index(remap.globals, global, "global"), source);
			case Call0(destination, callee): Call0(destination, index(remap.functions, callee, "function"));
			case Call1(destination, callee, argument): Call1(destination, index(remap.functions, callee, "function"), argument);
			case Call2(destination, callee, first, second): Call2(destination, index(remap.functions, callee, "function"), first, second);
			case CallN(destination, callee, arguments): CallN(destination, index(remap.functions, callee, "function"), arguments);
			case StaticClosure(destination, callee): StaticClosure(destination, index(remap.functions, callee, "function"));
			case InstanceClosure(destination, callee, receiver): InstanceClosure(destination, index(remap.functions, callee, "function"), receiver);
			case New(destination, type, extra): New(destination, index(remap.types, type, "allocated type"), extra);
			default: instruction;
		};
}
