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

	/** A field of a running object changed type (`name` is `Class.field`); its slot holds values of the old type. */
	ObjectFieldTypeChanged(name:String);

	/** The edit adds fields to an object whose reserved slots are all taken (see `HlModuleAssembler.planObjects`). */
	ObjectFieldReserveExhausted(name:String);

	/**
	 * A method the prototype must dispatch to changed (`name` is `Class.method`): an added method that overrides or is
	 * overridden, a removed override, or one the runtime calls by name.
	 */
	ObjectMethodDispatchChanged(name:String);
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
	 * closures that still hold one, as their code does. A function whose signature changed is the old function removed and a
	 * new one added under its name (`HlModuleAssembler` gives it a new slot), unless an object's prototype dispatches to it:
	 * the prototype keeps the old slot. Positionally named functions are still checked for renumbering, which an addition or
	 * removal can cause.
	 *
	 * `checksObjectMembers`: the assembler holds the layout the running module has, so it can take an object's added,
	 * removed and reordered fields and its added methods. An object whose kind, base and interfaces stayed the same is then
	 * left to the assembler, which checks its fields and methods against
	 * the layout the running module has (`HlModuleAssembler.planObjects`). Value objects and closure environments are not:
	 * other objects hold value objects inline, and closures already made hold their environments. A compiler resumed from
	 * saved identity state has the running module's ABI but not its layout, and passes false.
	 */
	public static function plan(previous:Null<RuntimeAbiDescriptor>, next:RuntimeAbiDescriptor, addsFunctions:Bool = false,
			checksObjectMembers:Bool = false):PatchDecision {
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
		var objectReasons:Array<AbiChange> = [];
		compare(previous.objects, next.objects, function(name, oldValue, newValue) {
			if (oldValue == null)
				return ObjectAdded(name);
			if (newValue == null)
				return ObjectRemoved(name);
			return StringTools.startsWith(name, compiler.semantic.LambdaName.ENVIRONMENT_PREFIX) ? ClosureLayoutChanged(name) : ObjectLayoutChanged(name);
		}, objectReasons);
		for (reason in objectReasons)
			switch reason {
				case ObjectLayoutChanged(name) if (checksObjectMembers && keepsFrame(previous.objects.get(name), next.objects.get(name))):
				default:
					reasons.push(reason);
			}
		compare(previous.interfaces, next.interfaces, function(name, oldValue, _) return oldValue == null ? InterfaceAdded(name) : InterfaceChanged(name),
			reasons);
		compare(previous.enums, next.enums, function(name, _, _) return EnumChanged(name), reasons);
		compare(previous.globals, next.globals, function(name, _, _) return GlobalLayoutChanged(name), reasons);
		for (group in renumberedGroups(previous.positional, next.positional, LambdaAlignment.placesOf(previous, next)))
			reasons.push(GeneratedFunctionsRenumbered(group));
		if (addsFunctions) {
			var dispatched = dispatchedFunctions(previous, next);
			reasons = [
				for (reason in reasons)
					if (!keepsLayout(reason, dispatched)) reason
			];
		}
		reasons.sort(function(a, b) return Reflect.compare(Std.string(a), Std.string(b)));
		return reasons.length == 0 ? Patch : ReloadDomain(reasons);
	}

	/**
	 * Whether two descriptions of an object (`RuntimeAbi.describe`) differ only in fields and methods, for an object that is
	 * not a value object.
	 */
	public static function keepsFrame(previous:Null<String>, next:Null<String>):Bool {
		if (previous == null || next == null)
			return false;
		var before = frame(previous), after = frame(next);
		return before != null && before == after;
	}

	static function frame(description:String):Null<String> {
		var parts:Array<String> = [];
		for (part in description.split(";")) {
			if (part == "kind=value")
				return null;
			if (!StringTools.startsWith(part, "fields=") && !StringTools.startsWith(part, "methods="))
				parts.push(part);
		}
		return parts.join(";");
	}

	/**
	 * The functions objects dispatch to through their prototypes (`methods=<name>:<function>` in `RuntimeAbi.describe`), in the
	 * running module (`previous`) or the new build. A prototype entry names a slot, so such a function cannot move to a new one
	 * (`movesOnSignatureChange`). The one place that decides it: the planner and the assembler (`HlModuleAssembler.assemble`)
	 * both use it.
	 */
	public static function dispatchedFunctions(previous:Null<RuntimeAbiDescriptor>, next:RuntimeAbiDescriptor):Map<String, Bool> {
		var result:Map<String, Bool> = [];
		if (previous != null)
			addMethodFunctions(previous.objects, result);
		addMethodFunctions(next.objects, result);
		return result;
	}

	static function addMethodFunctions(objects:Map<String, String>, result:Map<String, Bool>):Void {
		for (description in objects)
			for (part in description.split(";"))
				if (StringTools.startsWith(part, "methods="))
					for (method in part.substr("methods=".length).split(",")) {
						var separator = method.indexOf(":");
						if (separator > 0)
							result.set(method.substr(separator + 1), true);
					}
	}

	/** Whether a function whose signature changed can be given a new slot, the old one keeping its code (see `plan`). */
	public static function movesOnSignatureChange(name:String, dispatched:Map<String, Bool>):Bool
		return name != "__init" && !dispatched.exists(name);

	static function keepsLayout(reason:AbiChange, dispatched:Map<String, Bool>):Bool
		return switch reason {
			case FunctionAdded(_): true;
			case FunctionSignatureChanged(name): movesOnSignatureChange(name, dispatched);
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
	 * function's code.
	 *
	 * `LambdaAlignment` matches lambdas by their code and says how to rename the running module's lambdas so every name stands
	 * for its function again; a HashLink build applies those renames before it plans (`BackendAssembly`), so it gets here
	 * with nothing left to rename. A group is reported when it cannot be matched, or when it would need renaming: a module that
	 * cannot take the renames (a Wasm module, or one the compiler resumed without its layout) reloads instead. Function adapter
	 * groups are never renamed; they must keep every name's function (`LambdaAlignment.keepsNames`).
	 *
	 * Groups that only appear in one build are new or deleted functions, which have their own reasons.
	 */
	public static function renumberedGroups(previous:Null<Map<String, String>>, next:Null<Map<String, String>>,
			?places:LambdaAlignment.LambdaPlaces):Array<String> {
		var alignment = LambdaAlignment.align(previous, next, LambdaAlignment.PLANNING, places),
			result = alignment.refused.concat(alignment.renamed);
		result.sort(Reflect.compare);
		return result;
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
