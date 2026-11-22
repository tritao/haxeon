package compiler.hl.incremental;

import compiler.core.InternalError;
import compiler.hl.HlFunction;
import compiler.hl.HlFunction.HlInstruction;
import compiler.hl.incremental.HlSymbolRequest.HlRemap;
import compiler.hl.lower.HlLoweringView;

/** A lowered function given the indices of a build, or the reason it cannot have them. */
typedef HlLinked = {
	final fn:Null<HlFunction>;
	final reason:Null<String>;

	/** When the indices moved, the function as lowering it in this build would have recorded it; null when they all stay. */
	final ?rebased:HlLoweredFunction;
}

/**
 * The link step for lowered functions: gives a function that was lowered against one set of tables and one function layout the
 * indices of another, without lowering it again. It checks the facts the function read about object types, asks its requests of the
 * new tables (`HlRequestAnswers`, which also makes the tables what lowering the functions in order would have made them), and
 * rewrites the constant, type, global and function indices in its code, registers and debug names when some moved. A function whose
 * indices all stay is returned as it is, so the encoding cached for it stays valid.
 */
class HlLink {
	public static function link(lowered:HlLoweredFunction, answers:HlRequestAnswers, functions:Map<String, Int>,
			view:HlLoweringView):HlLinked {
		var stale = view.holds(lowered.facts);
		if (stale != null)
			return {fn: null, reason: 'fact $stale changed'};
		var keys = lowered.keys, recorded = lowered.answers, requests = answers.keys, moved = false;
		// The questions that add nothing to the tables first, so a function that must be lowered again has added nothing before it is:
		// lowering it asks in its own order.
		for (pass in 0...2)
			for (index in 0...keys.length) {
				var key = keys[index];
				if (requests.interns(key) != (pass == 1))
					continue;
				var answer = answers.answer(key), before = recorded[index];
				if (answer == before)
					continue;
				var table = requests.table(key);
				if (table == HlRequestKeys.CHECK || answer < 0 || before < 0)
					return {fn: null, reason: describe(requests.request(key))};
				moved = true;
			}
		var own = functions.get(lowered.name);
		if (own == null)
			return {fn: null, reason: 'function ${lowered.name} is not in the layout'};
		var before = lowered.fn;
		if (!moved && own == before.functionIndex)
			return {fn: before, reason: null};
		var remap = new HlRemap();
		var rebased = [for (index in 0...keys.length) {
			var key = keys[index], answer = answers.answer(key), table = requests.table(key);
			if (table != HlRequestKeys.CHECK)
				remap.note(table, recorded[index], answer);
			answer;
		}];
		var fn = new HlFunction(index(remap.types, before.type, "function type"), own,
			[for (register in before.registers) index(remap.types, register, "register type")],
			[for (instruction in before.opcodes) rewrite(instruction, remap)], before.debugLocations,
			[for (assignment in before.debugAssignments)
			{
				name:index(remap.strings, assignment.name, "debug name"), position:assignment.position,
					scopeEnd:assignment.scopeEnd
			}]);
		return {
			fn: fn,
			reason: null,
			rebased: new HlLoweredFunction(lowered.name, lowered.source, fn, keys, rebased, lowered.facts)
		};
	}

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
	static function index(map:Map<Int, Int>, from:Int, what:String):Int {
		var to = map.get(from);
		if (to == null)
			throw new InternalError('HashLink link: $what index $from was not requested while the function was lowered');
		return to;
	}

	static function rewrite(instruction:HlInstruction, remap:HlRemap):HlInstruction
		return switch instruction {
			case LoadInt(destination, constant): LoadInt(destination, index(remap.ints, constant, "integer constant"));
			case LoadFloat(destination, constant): LoadFloat(destination,
				index(remap.floats, constant, "float constant"));
			case LoadString(destination, constant): LoadString(destination, index(remap.strings, constant, "string"));
			case LoadType(destination, type): LoadType(destination, index(remap.types, type, "type"));
			case GlobalGet(destination, global): GlobalGet(destination, index(remap.globals, global, "global"));
			case GlobalSet(global, source): GlobalSet(index(remap.globals, global, "global"), source);
			case Call0(destination, callee): Call0(destination, index(remap.functions, callee, "function"));
			case Call1(destination, callee, argument): Call1(destination, index(remap.functions, callee, "function"),
				argument);
			case Call2(destination, callee, first, second): Call2(destination,
				index(remap.functions, callee, "function"), first, second);
			case CallN(destination, callee, arguments): CallN(destination, index(remap.functions, callee, "function"),
				arguments);
			case StaticClosure(destination, callee): StaticClosure(destination,
				index(remap.functions, callee, "function"));
			case InstanceClosure(destination, callee, receiver): InstanceClosure(destination,
				index(remap.functions, callee, "function"), receiver);
			case New(destination, type, extra): New(destination, index(remap.types, type, "allocated type"), extra);
			default: instruction;
		};
}
