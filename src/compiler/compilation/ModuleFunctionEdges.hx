package compiler.compilation;

import compiler.core.InternalError;
import compiler.modules.ModuleState;
import compiler.types.TypedAst.FunctionOriginKind;
import compiler.types.TypedAst.TypedFunction;

/** A function of a module as the prune reads it: whether it is a shared provider helper, and the shared helpers its IR calls. */
typedef HelperEdge = {
	final shared:Bool;

	/** The shared helpers its IR calls, each once, or null for none. */
	final calls:Null<Array<String>>;
}

/** A function of a module's IR as the retention of generated types reads it (`FrontendCompilation.retainedFromPrevious`). */
typedef RetentionEntry = {
	final name:String;

	/** The generated class whose method it is, or in whose method it is written (a lambda of one). */
	final owner:Null<String>;

	/** The hash of the enum specialization it is a helper of (`EnumRuntimeType.helperHash`). */
	final enumHash:Null<String>;

	/** The generic function specialization it is, or is made inside. */
	final specialization:Null<String>;

	/** The types retention may keep (`generatedTypeName`) that its IR names, or null for none. */
	final mentions:Null<FrontendCompilation.TypeMentions>;
}

/**
 * What the publication's whole-program questions read of one module's functions, as each function's contribution, kept with the
 * module (`ModuleState.functionEdges`): the shared provider helpers (`Provides.ProviderOperations.sharedAcrossModules`) and their
 * callers, which the prune reads (`stillCalled`), and what retention reads (`retention`). Each part is made the first time it is
 * asked for; a function changed or removed since is marked (`changed`) and read again the next time its part is asked for, so a
 * kept function is not read at all, and each part reads a changed function in the build that asks, as reading every body did.
 * A function with nothing to contribute has no entry. A module's copy has its own edges, so a build that is not taken leaves those
 * of the state it copied.
 */
class ModuleFunctionEdges {
	var helpers:Null<Map<String, HelperEdge>> = null;
	var helperChanges:Null<Map<String, Bool>> = null;
	var retained:Null<Map<String, RetentionEntry>> = null;
	var retainedChanges:Null<Map<String, Bool>> = null;

	public function new() {}

	public function copy():ModuleFunctionEdges {
		var result = new ModuleFunctionEdges();
		result.helpers = copied(helpers);
		result.helperChanges = copied(helperChanges);
		result.retained = copied(retained);
		result.retainedChanges = copied(retainedChanges);
		return result;
	}

	static function copied<T>(source:Null<Map<String, T>>):Null<Map<String, T>>
		return source == null ? null : [for (name => value in source) name => value];

	/** Marks the function `name` of `state` as changed or removed. */
	public static function changed(state:ModuleState, name:String):Void {
		var edges = state.functionEdges;
		if (edges == null)
			return;
		if (edges.helpers != null)
			edges.helperChanges = marked(edges.helperChanges, name);
		if (edges.retained != null)
			edges.retainedChanges = marked(edges.retainedChanges, name);
	}

	static function marked(changes:Null<Map<String, Bool>>, name:String):Map<String, Bool> {
		var result = changes == null ? new Map<String, Bool>():changes;
		result.set(name, true);
		return result;
	}

	static function edgesOf(state:ModuleState):ModuleFunctionEdges {
		var edges = state.functionEdges;
		if (edges == null) {
			edges = new ModuleFunctionEdges();
			state.functionEdges = edges;
		}
		return edges;
	}

	/**
	 * The names shared helpers are made under, one per generator. A call is recorded by its callee's name, as the callee may be in
	 * a module not read yet; `check` holds every shared helper to one of these.
	 */
	static final sharedPrefixes = [
		compiler.types.typing.ValueEqualityGenerator.PREFIX,
		compiler.types.typing.EnumEqualityGenerator.EQUALS_PREFIX,
		compiler.types.typing.EnumEqualityGenerator.REFLECTIVE_PREFIX,
		compiler.types.typing.HashGenerator.HASH_PREFIX,
		compiler.types.typing.EnumConformanceMethods.PREFIX,
		compiler.types.typing.FlagsGenerator.PREFIX,
		compiler.types.typing.RawEnumGenerator.PREFIX,
		compiler.types.typing.WireCodecGenerator.WIRE_PREFIX,
		compiler.types.typing.WireCodecGenerator.JSON_PREFIX
	];

	static function sharedName(name:String):Bool {
		if (StringTools.fastCodeAt(name, 0) != "$".code)
			return false;
		for (prefix in sharedPrefixes)
			if (StringTools.startsWith(name, prefix))
				return true;
		return false;
	}

	static function shared(fn:TypedFunction):Bool
		return switch fn.role {
			case ProviderFunction(_,
				operation): compiler.core.Provides.ProviderOperations.sharedAcrossModules(operation);
			default: false;
		};

	/**
	 * Whether `name` is a generated class or enum that retention may keep (a generic owner or enum specialization, an enum's
	 * interface adapter, a key path cache), by its name: `FrontendCompilation.retainedFromPrevious` checks this of every one it may
	 * retain.
	 */
	public static function generatedTypeName(name:String):Bool
		return compiler.semantic.GeneratedNames.isSpecialization(name)
			|| StringTools.startsWith(name, compiler.types.typing.EnumInterfaceAdapter.PREFIX)
			|| name.indexOf(compiler.types.typing.EnumRuntimeType.SEPARATOR) >= 0
			|| name.indexOf(compiler.types.typing.KeyPathRuntime.CACHE_SEPARATOR) >= 0;

	/** The prune's part of the module's edges, brought up to date with its functions. */
	public static function helperEdges(state:ModuleState):Map<String, HelperEdge> {
		var edges = edgesOf(state), part = edges.helpers;
		if (part == null) {
			part = [];
			for (name in state.typedFunctions.keys())
				if (!state.irFunctions.exists(name))
					update(part, name, helperEdge(state, name));
			for (name in state.irFunctions.keys())
				update(part, name, helperEdge(state, name));
			edges.helpers = part;
			return part;
		}
		var changes = edges.helperChanges;
		if (changes != null) {
			edges.helperChanges = null;
			for (name in changes.keys())
				update(part, name, helperEdge(state, name));
		}
		return part;
	}

	/** Retention's part of the module's edges, brought up to date with its functions: one entry per IR function that has one. */
	public static function retention(state:ModuleState):Map<String, RetentionEntry> {
		var edges = edgesOf(state), part = edges.retained;
		if (part == null) {
			part = [];
			for (name in state.irFunctions.keys())
				update(part, name, retentionEntry(state, name));
			edges.retained = part;
			return part;
		}
		var changes = edges.retainedChanges;
		if (changes != null) {
			edges.retainedChanges = null;
			for (name in changes.keys())
				update(part, name, retentionEntry(state, name));
		}
		return part;
	}

	static function update<T>(part:Map<String, T>, name:String, value:Null<T>):Void
		if (value != null)
			part.set(name, value);
		else
			part.remove(name);

	static function helperEdge(state:ModuleState, name:String):Null<HelperEdge> {
		var fn = state.typedFunctions.get(name), ir = state.irFunctions.get(name);
		var isShared = fn != null && shared(fn), calls:Null<Array<String>> = null;
		if (ir != null)
			for (callee in FrontendCompilation.callsIn(ir))
				if (sharedName(callee)) {
					if (calls == null)
						calls = [];
					calls.push(callee);
				}
		return !isShared && calls == null ? null : {shared: isShared, calls: calls};
	}

	static function retentionEntry(state:ModuleState, name:String):Null<RetentionEntry> {
		var ir = state.irFunctions.get(name);
		if (ir == null)
			return null;
		// A lambda belongs to the method it is written in: one in a generated class's method names that class as the method does.
		var root = state.typedFunctions.get(name);
		while (root != null && root.physicalOwner == null && root.originKind == FunctionOriginKind.Lambda
			&& root.origin != null)
			root = state.typedFunctions.get(root.origin);
		var owner = root == null ? null : root.physicalOwner,
			enumHash = compiler.types.typing.EnumRuntimeType.helperHash(name),
			specialization = FrontendCompilation.functionSpecializationOf(state, name),
			named = FrontendCompilation.typeMentions(ir),
			mentions = namesGenerated(named) ? named : null;
		if (owner == null && enumHash == null && specialization == null && mentions == null)
			return null;
		return {
			name: name,
			owner: owner,
			enumHash: enumHash,
			specialization: specialization,
			mentions: mentions
		};
	}

	static function namesGenerated(named:FrontendCompilation.TypeMentions):Bool {
		for (name in named.classes)
			if (generatedTypeName(name))
				return true;
		for (name in named.enums)
			if (generatedTypeName(name))
				return true;
		return false;
	}

	/**
	 * The shared helpers still called, directly or through other helpers, by a function of `names`' modules that stays and is not
	 * typed again (`typedAgain`), or by a helper that stays on its own (typed again, or made for an origin that stays and is not
	 * invalidated). A shared helper has one recorded origin: when that origin is edited or stops asking for it, pruning by origin
	 * alone would drop a dependency of another caller that stays. The modules holding such helpers join `names`, which is sorted.
	 */
	public static function stillCalled(modules:Map<String, ModuleState>, names:Array<String>,
			typedAgain:(ModuleState, String) -> Bool, owners:Map<String, String>,
			invalidated:Map<String, Bool>):Map<String, Bool> {
		var reachable = [for (name in names) name => true];
		var holders:Map<String, ModuleState> = [],
			kept:Map<String, Bool> = [],
			pending:Array<String> = [];
		for (name => state in modules) {
			var inProgram = reachable.exists(name);
			for (helper => edge in helperEdges(state)) {
				if (!edge.shared)
					continue;
				if (!holders.exists(helper) || inProgram)
					holders.set(helper, state);
				if (!inProgram)
					continue;
				var fn = state.typedFunctions.get(helper), origin = fn == null ? null : fn.origin;
				if (typedAgain(state, helper) || origin != null && owners.exists(origin)
					&& !invalidated.exists(origin)) {
					kept.set(helper, true);
					pending.push(helper);
				}
			}
		}
		var result:Map<String, Bool> = [];
		function call(callee:String, holder:ModuleState):Void {
			result.set(callee, true);
			if (!reachable.exists(holder.name)) {
				reachable.set(holder.name, true);
				names.push(holder.name);
			}
			if (!kept.exists(callee)) {
				kept.set(callee, true);
				pending.push(callee);
			}
		}
		for (name in names.copy()) {
			var state = modules.get(name);
			if (state != null)
				for (caller => edge in helperEdges(state)) {
					var called = edge.calls;
					if (called != null && owners.exists(caller) && !typedAgain(state, caller))
						for (callee in called) {
							var holder = holders.get(callee);
							if (holder != null && !invalidated.exists(callee))
								call(callee, holder);
						}
				}
		}
		while (true) {
			var helper = pending.pop();
			if (helper == null)
				break;
			var holder = holders.get(helper),
				edge = holder == null ? null : helperEdges(holder).get(helper),
				called = edge == null ? null : edge.calls;
			if (called != null)
				for (callee in called) {
					var calleeHolder = holders.get(callee);
					if (calleeHolder != null)
						call(callee, calleeHolder);
				}
		}
		names.sort(Reflect.compare);
		return result;
	}

	/**
	 * Check mode: every module of `names` keeps the edges its functions give afresh, and every shared helper is named as
	 * `sharedPrefixes` say, so no call of one goes unrecorded.
	 */
	public static function check(session:SessionState, names:Array<String>):Void
		for (name in names) {
			var state = session.modules.get(name);
			if (state == null)
				continue;
			for (helper => fn in state.typedFunctions)
				if (shared(fn) && !sharedName(helper))
					throw new InternalError('shared helper "$helper" is not named as a shared helper');
			var kept = helperEdges(state);
			for (fnName in state.typedFunctions.keys())
				if (!sameHelper(helperEdge(state, fnName), kept.get(fnName)))
					throw new InternalError('module "$name" keeps another helper edge of "$fnName" than the function gives');
			for (fnName in state.irFunctions.keys())
				if (!sameHelper(helperEdge(state, fnName), kept.get(fnName)))
					throw new InternalError('module "$name" keeps another helper edge of "$fnName" than the function gives');
			for (fnName in kept.keys())
				if (!state.typedFunctions.exists(fnName) && !state.irFunctions.exists(fnName))
					throw new InternalError('module "$name" keeps a helper edge of "$fnName", which it does not hold');
			var retained = retention(state);
			for (fnName in state.irFunctions.keys())
				if (!sameEntry(retentionEntry(state, fnName), retained.get(fnName)))
					throw new InternalError('module "$name" keeps another retention entry of "$fnName" than the function gives');
			for (fnName in retained.keys())
				if (!state.irFunctions.exists(fnName))
					throw new InternalError('module "$name" keeps a retention entry of "$fnName", which it does not hold');
		}

	static function sameHelper(left:Null<HelperEdge>, right:Null<HelperEdge>):Bool
		return left == null ? right == null : right != null && left.shared == right.shared
			&& sameNames(left.calls, right.calls);

	static function sameEntry(left:Null<RetentionEntry>, right:Null<RetentionEntry>):Bool {
		if (left == null || right == null)
			return left == right;
		var leftMentions = left.mentions, rightMentions = right.mentions;
		return left.owner == right.owner && left.enumHash == right.enumHash
			&& left.specialization == right.specialization
			&& (leftMentions == null ? rightMentions == null : rightMentions != null
			&& FrontendCompilation.sameTypeMentions(leftMentions, rightMentions));
	}

	static function sameNames(left:Null<Array<String>>, right:Null<Array<String>>):Bool
		return left == null ? right == null : right != null
			&& compiler.ir.model.Ir.IrObjectTools.sameNames(left, right);
}
