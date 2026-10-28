package compiler.abi;

import compiler.abi.RuntimeAbi.RuntimeAbiDescriptor;

/** Runtime-visible structural change that may require a domain reload. */
enum AbiChange {
	FunctionAdded(name:String);
	FunctionRemoved(name:String);
	FunctionSignatureChanged(name:String);
	ObjectAdded(name:String);
	ObjectRemoved(name:String);
	ObjectLayoutChanged(name:String);
	ClosureLayoutChanged(name:String);
	InterfaceChanged(name:String);

	/** An interface the previous build did not have. Only new classes can implement it, so no loaded layout changes. */
	InterfaceAdded(name:String);
	EnumChanged(name:String);
	GlobalLayoutChanged(name:String);

	/**
	 * Positionally named functions in this group may stand for different functions than the names did before (see
	 * `PatchPlanner.renumberedGroups`).
	 */
	GeneratedFunctionsRenumbered(group:String);

	/** The assembler could not keep the running module's slots or globals (`detail` names which). */
	AssemblyLayoutChanged(detail:String);
}

/** Permitted publication strategy after comparing two runtime ABIs. */
enum PatchDecision {
	Patch;
	ReloadDomain(reasons:Array<AbiChange>);
	Reject(diagnostics:Array<String>);
}

/** Compares the exact ABI descriptors consumed by HL lowering. */
class PatchPlanner {
	/**
	 * `addsFunctions`: the running module can take functions and types a patch adds (HashLink live patching), so a new function
	 * is not a reason to reload, and neither is a removed one: its slot and last body stay in the module, and the new code does
	 * not call it. A removed constructor still reloads, since it goes with a class. A new class or closure environment is a type
	 * the patch appends to the module's type table. A removed closure environment or capture cell stays in the table for the
	 * closures that still hold one, as their code does. Positionally named functions are still checked for renumbering, which
	 * an addition or removal can cause.
	 */
	public static function plan(previous:Null<RuntimeAbiDescriptor>, next:RuntimeAbiDescriptor, addsFunctions:Bool = false):PatchDecision {
		if (previous == null)
			return Patch;
		var reasons:Array<AbiChange> = [];
		compare(previous.functions, next.functions, function(name, oldValue, newValue) {
			if (oldValue == null)
				return FunctionAdded(name);
			if (newValue == null)
				return FunctionRemoved(name);
			return FunctionSignatureChanged(name);
		}, reasons);
		compare(previous.objects, next.objects, function(name, oldValue, newValue) {
			if (oldValue == null)
				return ObjectAdded(name);
			if (newValue == null)
				return ObjectRemoved(name);
			return StringTools.startsWith(name, "$lambda-env:") ? ClosureLayoutChanged(name) : ObjectLayoutChanged(name);
		}, reasons);
		compare(previous.interfaces, next.interfaces, function(name, oldValue, _) return oldValue == null ? InterfaceAdded(name) : InterfaceChanged(name),
			reasons);
		compare(previous.enums, next.enums, function(name, _, _) return EnumChanged(name), reasons);
		compare(previous.globals, next.globals, function(name, _, _) return GlobalLayoutChanged(name), reasons);
		for (group in renumberedGroups(previous.positional, next.positional))
			reasons.push(GeneratedFunctionsRenumbered(group));
		if (addsFunctions)
			reasons = [
				for (reason in reasons)
					if (!keepsLayout(reason)) reason
			];
		reasons.sort(function(a, b) return Reflect.compare(Std.string(a), Std.string(b)));
		return reasons.length == 0 ? Patch : ReloadDomain(reasons);
	}

	static function keepsLayout(reason:AbiChange):Bool
		return switch reason {
			case FunctionAdded(_): true;
			case FunctionRemoved(name): !StringTools.endsWith(name, ".new");
			case ObjectAdded(_), InterfaceAdded(_): true;
			case ObjectRemoved(name): isGeneratedType(name);
			default: false;
		};

	/** Types the compiler makes for closures: their environments and the cells of the locals they capture. */
	static function isGeneratedType(name:String):Bool {
		for (prefix in ["$lambda-env:", "$function-adapter-env:", "$cell:"])
			if (StringTools.startsWith(name, prefix))
				return true;
		return false;
	}

	/** Whether producing the replacement module requires discarding backend tombstones and layout caches. */
	public static function requiresFreshLayout(decision:PatchDecision):Bool
		return switch decision {
			case Patch, Reject(_): false;
			case ReloadDomain(reasons): [
					for (reason in reasons)
						switch reason {
							case FunctionAdded(_), FunctionSignatureChanged(_), GeneratedFunctionsRenumbered(_):
								false;
							case FunctionRemoved(name):
								StringTools.endsWith(name, ".new");
							default:
								true;
						}
				].indexOf(true) >= 0;
		};

	/**
	 * Groups of positionally named functions (`PositionalName`) that cannot be shown to keep their names. A lambda or function
	 * adapter is named by its position among its siblings, and a patch puts the new code under each name; closures the running
	 * program already made call the code under their name. That is right only while every name stands for the function it
	 * stood for before. Inserting, deleting or reordering siblings shifts names onto other functions, and when the shifted
	 * functions have the same signature and captures nothing else notices: stored callbacks would silently run another
	 * function's code. So a group may patch only when its functions are provably the same, by their code fingerprints:
	 *
	 * - None changed, or functions were only added or removed after the last one that is kept: every kept name runs its old code.
	 * - Exactly one changed, the count is the same, and neither its old nor its new code appears elsewhere in the group: that is
	 *   an edit of that function. (A sibling inserted above and a later one deleted changes every name in between, unless those
	 *   siblings have identical code, which the uniqueness check rules out.)
	 *
	 * Anything else reloads. Groups that only appear in one build are new or deleted functions, which have their own reasons.
	 */
	public static function renumberedGroups(previous:Null<Map<String, String>>, next:Null<Map<String, String>>):Array<String> {
		var before = groups(previous),
			after = groups(next),
			renumbered:Array<String> = [];
		for (group => nextCode in after) {
			var previousCode = before.get(group);
			if (previous == null || previousCode != null && !sameFunctions(previousCode, nextCode))
				renumbered.push(group);
		}
		renumbered.sort(Reflect.compare);
		return renumbered;
	}

	static function groups(fingerprints:Null<Map<String, String>>):Map<String, Array<Null<String>>> {
		var result:Map<String, Array<Null<String>>> = [];
		if (fingerprints == null)
			return result;
		for (name => fingerprint in fingerprints) {
			var group = PositionalName.group(name),
				members:Array<Null<String>>;
			if (result.exists(group))
				members = result.get(group);
			else {
				members = [];
				result.set(group, members);
			}
			members[PositionalName.ordinal(name)] = fingerprint;
		}
		return result;
	}

	static function sameFunctions(previous:Array<Null<String>>, next:Array<Null<String>>):Bool {
		var changed:Array<Int> = [];
		for (ordinal in 0...(previous.length < next.length ? previous.length : next.length))
			if (previous[ordinal] == null || previous[ordinal] != next[ordinal])
				changed.push(ordinal);
		if (changed.length == 0)
			return true;
		if (changed.length > 1 || previous.length != next.length)
			return false;
		var ordinal = changed[0];
		return occurrences(previous, previous[ordinal]) == 1 && occurrences(next, next[ordinal]) == 1;
	}

	static function occurrences(sources:Array<Null<String>>, source:Null<String>):Int {
		var count = 0;
		for (candidate in sources)
			if (candidate == source)
				count++;
		return count;
	}

	static function compare(previous:Map<String, String>, next:Map<String, String>, change:(String, Null<String>, Null<String>) -> AbiChange,
			reasons:Array<AbiChange>):Void {
		var names:Map<String, Bool> = [];
		for (name in previous.keys())
			names.set(name, true);
		for (name in next.keys())
			names.set(name, true);
		for (name in names.keys()) {
			var oldValue = previous.get(name), newValue = next.get(name);
			if (oldValue != newValue)
				reasons.push(change(name, oldValue, newValue));
		}
	}
}
