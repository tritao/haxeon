package compiler.hl.incremental;

import compiler.core.InternalError;
import compiler.hl.HlFunction;
import compiler.hl.HlFunction.HlInstruction;
import compiler.hl.incremental.HlSymbolRequest.HlRemap;
import compiler.hl.lower.HlLoweringView;

/**
 * Relocation of lowered functions: whether a function lowered against one build's tables and function layout holds in another's,
 * without lowering it again. A build keeps every function as the build that lowered it made it and rewrites none (`relocate`): its
 * sections name entries by key, so a function's indices only need to be found in the build's tables, never written back into
 * its code. A tool that shows one function with this build's indices rewrites it (`rewritten`, `HlRelocations.materialize`).
 */
class HlLink {
	/** `relocate`: the function does not hold in this build, and is lowered again. */
	public static inline final STALE = -1;

	/** `relocate`: the function holds, and every index its code uses is the same in this build's tables. */
	public static inline final STAYS = 0;

	/** `relocate`: the function holds, and `remap` gives the indices that are others in this build's tables. */
	public static inline final MOVES = 1;

	/**
	 * Whether `lowered`, kept as the build that lowered it made it, holds in this build: the facts it read hold, and every
	 * request but the ones that index a table has the answer it had. Asks every request, so this build's tables hold what the
	 * function names; `STALE`, `STAYS`, or `MOVES` with `remap` filled.
	 */
	public static function relocate(lowered:HlLoweredFunction, answers:HlRequestAnswers, view:HlLoweringView,
			remap:HlRemap):Int {
		if (view.holds(lowered.facts) != null)
			return STALE;
		var keys = lowered.keys, recorded = lowered.answers, requests = answers.keys, moved = false;
		for (index in 0...keys.length) {
			var key = keys[index], answer = answers.answer(key), before = recorded[index];
			if (answer != before) {
				if (requests.table(key) == HlRequestKeys.CHECK || answer < 0 || before < 0)
					return STALE;
				moved = true;
			}
		}
		return !moved ? STAYS : fill(lowered, answers, remap) == null ? MOVES : STALE;
	}

	/**
	 * Fills `remap` with where this build's tables hold each index `lowered`'s code uses; null when they do, else the request that
	 * shared an index with another and now has its own.
	 */
	public static function fill(lowered:HlLoweredFunction, answers:HlRequestAnswers, remap:HlRemap):Null<String> {
		var keys = lowered.keys, recorded = lowered.answers, requests = answers.keys;
		remap.start();
		for (index in 0...keys.length) {
			var key = keys[index], table = requests.table(key), before = recorded[index];
			// A request answered with no entry (a field without narrow storage) names nothing the code uses.
			if (table != HlRequestKeys.CHECK && before >= 0 && !remap.note(table, before, answers.answer(key)))
				return describe(requests.request(key)) + ", which shared an index with another request";
		}
		return null;
	}

	/** `fn` with the indices `remap` gives it, as function `own`. */
	public static function rewritten(fn:HlFunction, own:Int, remap:HlRemap):HlFunction
		return new HlFunction(index(remap, HlRequestKeys.TYPES, fn.type, "function type"), own,
			[for (register in fn.registers) index(remap, HlRequestKeys.TYPES, register, "register type")],
			[for (instruction in fn.opcodes) rewrite(instruction, remap)], fn.debugLocations,
			[for (assignment in fn.debugAssignments)
			{
				name: index(remap, HlRequestKeys.STRINGS, assignment.name, "debug name"), position: assignment.position,
				scopeEnd: assignment.scopeEnd
			}]);

	static function describe(request:HlSymbolRequest):String
		return switch request {
			case FieldSlot(owner, name, _): 'field $owner.$name moved';
			case MethodSlot(typeName, name, _): 'method $typeName.$name moved';
			case InterfaceSlot(interfaceName, name, _): 'interface method $interfaceName.$name moved';
			case MethodSlotKnown(typeName, name, _): 'method slot of $typeName.$name changed';
			case FunctionRef(name, _): 'function $name is gone';
			case NativeStorage(type, _, _): "native storage of " + Std.string(type);
			default: 'request ${Std.string(request)} changed';
		};

	/** An index the function uses must be one of its requests: anything else would be moved by no one. */
	static function index(remap:HlRemap, table:Int, from:Int, what:String):Int {
		var to = remap.get(table, from);
		if (to < 0)
			throw new InternalError('HashLink link: $what index $from was not requested while the function was lowered');
		return to;
	}

	static function rewrite(instruction:HlInstruction, remap:HlRemap):HlInstruction
		return switch instruction {
			case LoadInt(destination, constant): LoadInt(destination,
				index(remap, HlRequestKeys.INTS, constant, "integer constant"));
			case LoadFloat(destination, constant): LoadFloat(destination,
				index(remap, HlRequestKeys.FLOATS, constant, "float constant"));
			case LoadString(destination, constant): LoadString(destination,
				index(remap, HlRequestKeys.STRINGS, constant, "string"));
			case LoadType(destination, type): LoadType(destination, index(remap, HlRequestKeys.TYPES, type, "type"));
			case GlobalGet(destination, global): GlobalGet(destination,
				index(remap, HlRequestKeys.GLOBALS, global, "global"));
			case GlobalSet(global, source): GlobalSet(index(remap, HlRequestKeys.GLOBALS, global, "global"), source);
			case Call0(destination, callee): Call0(destination,
				index(remap, HlRequestKeys.FUNCTIONS, callee, "function"));
			case Call1(destination, callee, argument): Call1(destination,
				index(remap, HlRequestKeys.FUNCTIONS, callee, "function"),
				argument);
			case Call2(destination, callee, first, second): Call2(destination,
				index(remap, HlRequestKeys.FUNCTIONS, callee, "function"), first, second);
			case CallN(destination, callee, arguments): CallN(destination,
				index(remap, HlRequestKeys.FUNCTIONS, callee, "function"),
				arguments);
			case StaticClosure(destination, callee): StaticClosure(destination,
				index(remap, HlRequestKeys.FUNCTIONS, callee, "function"));
			case InstanceClosure(destination, callee, receiver): InstanceClosure(destination,
				index(remap, HlRequestKeys.FUNCTIONS, callee, "function"), receiver);
			case New(destination, type, extra): New(destination,
				index(remap, HlRequestKeys.TYPES, type, "allocated type"), extra);
			default: instruction;
		};
}
