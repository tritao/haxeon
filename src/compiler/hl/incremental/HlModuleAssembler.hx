package compiler.hl.incremental;

import compiler.core.InternalError;
import compiler.core.SourceAnchor.SourceAnchors;
import compiler.ir.model.IrBuilder;
import compiler.ir.pipeline.IrProgramAssembler;
import compiler.ir.model.IrFunction;
import compiler.ir.model.Ir.IrDefault;
import compiler.ir.model.Ir.IrType;
import compiler.ir.model.Ir.IrValue;
import compiler.semantic.LambdaName;
import compiler.hl.lower.HlLower;
import compiler.ir.model.Ir.IrProgram;
import compiler.ir.codec.IrTypeCodec;
import compiler.abi.NameRewrite;
import compiler.abi.RetiredName;
import compiler.abi.PatchPlanner;
import compiler.abi.PatchPlanner.AbiChange;
import compiler.abi.PatchPlanner.PatchDecision;
import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.patch.HlObjectLayout;
import compiler.ir.model.Ir.IrObject;
import compiler.hl.HlCode;
import compiler.hl.HlFunction;
import compiler.hl.persistence.HlFunctionCacheStateCodec;
import compiler.hl.persistence.HlSymbolStateCodec;
import compiler.ir.model.Ir.IrNative;
import compiler.core.AllocationMeter.PhaseAllocation;

/** Persisted append-only symbol and function baseline for incremental assembly. */
typedef HlAssemblerState = {
	final initialized:Bool;
	final revision:Int;
	final publishedInts:Int;
	final publishedFloats:Int;
	final publishedStrings:Int;
	final publishedTypes:Int;

	/** Globals the published module holds. Absent in older baselines, which published no literal globals. */
	@:optional final publishedGlobals:Int;

	final symbols:haxe.io.Bytes;
	final cache:haxe.io.Bytes;
	@:optional final runtimeNatives:Array<IrNative>;

	/** Names of the C dispatch natives, which follow the runtime natives in the layout. Absent in older baselines. */
	@:optional final dispatchNatives:Array<String>;

	/** `HlModuleAssembler.retiredFields`, as `Class.field` names. Absent in older baselines, which retired none. */
	@:optional final retiredFields:Array<String>;

	/** `HlModuleAssembler.sectionDigests`, as path and digest pairs. */
	final sections:Array<{path:String, digest:String}>;
}

/** What `HlModuleAssembler.planObjects` found: the changes a patch cannot make, or the layout the patch changes (null for none). */
private typedef ObjectPlan = {
	final reasons:Array<AbiChange>;
	final layout:Null<HlObjectLayout>;
}

/** Module plus identity and delta metadata produced by one assembly transaction. */
/** What `HlModuleAssembler.moveChangedSignatures` did: the functions it moved, the retired slots it gave adapters, and those it could not. */
typedef SignatureMoves = {
	final moved:Array<String>;
	final adapted:Array<String>;
	final guards:Array<{name:String, description:String}>;
}

typedef HlAssemblyResult = {
	final module:HlCode;
	final unchanged:Bool;
	final baseRevision:Int;
	/** The functions this build lowered again that the running module has, by name, sorted. */
	final changedFunctions:Array<String>;

	/**
	 * Functions this build drops that closures the running program stored may still reach, with what happened to each: the
	 * patch applies only when no live closure refers to them (`HlSectionPatch`, guards).
	 */
	final guards:Array<{name:String, description:String}>;

	/**
	 * What of the running module this build gives other names, as their names were and are: a lambda its siblings renumbered
	 * (`renameLambdas`) with its environment and the environment's class value, and a function whose signature changed
	 * (`moveChangedSignatures`).
	 */
	final renames:Array<{from:String, to:String}>;

	final functionIndices:Map<String, Int>;
	final requiresReload:Bool;

	/** Why the assembler published a fresh module on its own, beyond the ABI plan's reasons. */
	final layoutReasons:Array<String>;

	/** Object changes the running module cannot take, which made the assembler publish a fresh module. */
	final objectReasons:Array<AbiChange>;

	/** The object fields this build adds to the running module, null without any. */
	final objectLayout:Null<HlObjectLayout>;

	final revision:Int;
	final cachePreparationMs:Float;
	final loweringMs:Float;
	final publicationMs:Float;
	final verificationMs:Float;
	final metadataMs:Float;
	final functionLoweringMs:Float;
	final debugAssemblyMs:Float;
	final lowerFinalizationMs:Float;
	final allocationPhases:Array<PhaseAllocation>;
}

/**
 * Stateful IR-to-HashLink assembler with append-only published indices.
 * Callers publish or discard a copied instance as one compiler transaction.
 */
class HlModuleAssembler {
	public var symbols(default, null) = new HlSymbolTable();
	public var cache(default, null):HlFunctionCache;

	var initialized:Bool = false;
	var revision:Int = 0;

	/**
	 * Revisions up to this one were handed out already, by this assembler's history or one it replaces, so the next build is
	 * numbered after it. A fresh layout under the same module identity, or a published revision the live host refused and the
	 * compiler took back, must never reuse a number: the host tells builds apart by identity and revision.
	 */
	var revisionFloor:Int = 0;

	var publishedInts = 0;
	var publishedFloats = 0;
	var publishedStrings = 0;
	var publishedTypes = 0;
	var publishedGlobals = 0;

	/**
	 * The functions of the published module, as live patching keeps them: trusted by name, with no requests (see
	 * `HlLower.trustCache`), with the sections the last live build wrote (`HlLoweredCache.sections`).
	 */
	var published = new HlLoweredCache();

	/**
	 * The run of live builds whose tables extend one another's with nothing in them renamed (`HlRelocations.chain`): a fresh
	 * layout and a rename start another, so that a section is kept without collecting it only while what it names reads the same.
	 */
	var liveChain = 0;

	/**
	 * The digest of each section of the module this assembler last published, by path (`HlSectionWriter`): a live patch replaces
	 * the sections whose digests the next build changes. Empty before the first module of sections.
	 */
	public var sectionDigests(default, null):Map<String, String> = [];

	/** The renames since the last assembly (`HlAssemblyResult.renames`). */
	var pendingRenames:Array<{from:String, to:String}> = [];

	var runtimeNatives:Array<IrNative> = [];

	/** Null when a restored baseline does not record them, so the next build cannot trust their slots. */
	var dispatchNatives:Null<Array<String>> = [];

	/**
	 * Fields of published objects that the last published program no longer has, as `Class.field`. Each keeps its slot, its
	 * name and the values instances had (see `planObjects`), so when the field comes back the running module has it already;
	 * but instances made while it was gone never ran its initializer, and the others hold a stale value. So the field counts
	 * as one the running module lacks (`publishedField`), and its initializer runs on every instance again.
	 */
	var retiredFields:Map<String, Bool> = [];

	/**
	 * The functions of the program the last build assembled, so the next one knows which it drops (see `dropGuards`); null
	 * when unknown, after a restore, when every function no build has is treated as dropped.
	 */
	var programNames:Null<Map<String, Bool>> = null;

	/**
	 * The functions whose code in the module is a declaration stub (`IrProgram.stubbedFunctions`): a method no build reached
	 * since it took its slot. Not kept across a restore, after which every slot counts as holding real code, which keeps what a
	 * stub would replace and so is never wrong.
	 */
	var stubs:Map<String, Bool> = [];

	/**
	 * Reserved slots each object gets when this assembler lays out a fresh module (see `HlLower.reservedSlots`): the
	 * fields live patches can add to it. Zero without live patching.
	 */
	public var fieldReserve:Int = 0;

	public var developmentMetadata:Bool = true;

	/**
	 * The build's sources, which place the module's debug locations (`HlCode.sources`); a build sets them for each assembly, as they
	 * remember what they placed. Without them an assembly places anchors where they were last declared.
	 */
	public var sources:Null<SourceAnchors> = null;

	/** Lower what the lowering cache would reuse again and compare (`CompileOptions.checkReuse`). */
	public var checkReuse:Bool = false;

	/** The functions of the last plain build to keep instead of lowering again, and the ones this build lowers (see `HlLoweredCache`). */
	public var loweredCache:Null<HlLoweredCache>;

	/** The build patches a running module: functions are kept by name (`published`). Otherwise they are kept from `loweredCache`. */
	public var livePatching = false;

	/**
	 * A next build may link this one's lowered functions, so lowering records what each read (`HlLoweringView`). Off for a
	 * compile that keeps no session (`CompileOptions.keepSession`), which neither links nor records.
	 */
	public var keepsLowered = true;

	/** The IR given to `assemble` was verified already (a plain build verifies its final IR before any backend). */
	public var irVerified = false;

	/** Keep the program the last assembly lowered (`lastProgram`), for a backend that lowers it again (the C backend). */
	public var keepsProgram = false;

	/** The program the last assembly lowered, after the shared runtime calls; null unless `keepsProgram`. */
	public var lastProgram(default, null):Null<IrProgram> = null;

	/** How many functions the last `assemble` took from `loweredCache`. */
	public var reusedFunctions = 0;

	/** How many of those got other indices than they were lowered with. */
	public var movedFunctions = 0;

	/** Methods HashLink's runtime finds by name in the prototype, which a direct call cannot stand in for. */
	static final runtimeMethods:Array<String> = ["__string", "__compare", "__cast", "__get_field"];

	public function new()
		cache = new HlFunctionCache();

	public function copy():HlModuleAssembler {
		var result = new HlModuleAssembler();
		result.symbols = symbols.fork();
		result.cache = cache.copy();
		result.initialized = initialized;
		result.revision = revision;
		result.revisionFloor = revisionFloor;
		result.publishedInts = publishedInts;
		result.publishedFloats = publishedFloats;
		result.publishedStrings = publishedStrings;
		result.publishedTypes = publishedTypes;
		result.publishedGlobals = publishedGlobals;
		result.published = published.copy();
		result.liveChain = liveChain;
		result.sectionDigests = sectionDigests.copy();
		result.pendingRenames = pendingRenames.copy();
		result.livePatching = livePatching;
		result.keepsLowered = keepsLowered;
		result.runtimeNatives = runtimeNatives.copy();
		result.dispatchNatives = dispatchNatives == null ? null : dispatchNatives.copy();
		result.fieldReserve = fieldReserve;
		result.developmentMetadata = developmentMetadata;
		result.loweredCache = loweredCache;
		result.irVerified = irVerified;
		result.retiredFields = [for (name in retiredFields.keys()) name => true];
		result.renamed = renamed.copy();
		result.programNames = programNames == null ? null : [for (name in programNames.keys()) name => true];
		result.stubs = stubs.copy();
		return result;
	}

	/** The sections the last live build wrote, which the next keeps those it writes alike from; null after a fresh layout. */
	public function liveSections():Null<compiler.hl.HlSectionWriter.HlSectionCache>
		return livePatching ? published.sections : null;

	/** Records the sections the module this assembler assembled was written as (`sectionDigests`, `liveSections`). */
	public function wroteSections(cache:compiler.hl.HlSectionWriter.HlSectionCache,
			written:Array<compiler.hl.HlSectionWriter.HlWrittenSection>):Void {
		if (livePatching)
			published.sections = cache;
		sectionDigests = [for (section in written) section.path => section.digest];
	}

	/** Whether this assembler has published a module, so an object it published can take added fields. */
	public function isPublished():Bool
		return initialized;

	/**
	 * Whether object `objectName` has a field `fieldName` in the module this assembler published. False for an object it
	 * has not published: the object is new, and nothing needs its fields initialized.
	 */
	public function publishedField(objectName:String, fieldName:String):Bool
		return initialized
			&& symbols.objectFieldIndex(objectName, fieldName) != null
			&& !retiredFields.exists(objectName + "." + fieldName);

	public function publishedObject(objectName:String):Bool
		return initialized && symbols.objectDefinition(objectName) != null;

	public function exportState():HlAssemblerState
		return {
			initialized: initialized,
			revision: revision,
			publishedInts: publishedInts,
			publishedFloats: publishedFloats,
			publishedStrings: publishedStrings,
			publishedTypes: publishedTypes,
			publishedGlobals: publishedGlobals,
			symbols: HlSymbolStateCodec.encode(symbols.exportState()),
			cache: HlFunctionCacheStateCodec.encode(cache.exportState()),
			runtimeNatives: runtimeNatives.copy(),
			dispatchNatives: dispatchNatives == null ? null : dispatchNatives.copy(),
			retiredFields: [for (name in retiredFields.keys()) name],
			sections: [for (path => digest in sectionDigests) {path: path, digest: digest}]
		};

	public static function fromState(state:HlAssemblerState):HlModuleAssembler {
		var result = new HlModuleAssembler();
		result.symbols = HlSymbolStateCodec.restore(state.symbols);
		result.cache = HlFunctionCacheStateCodec.restore(state.cache);
		if (state.runtimeNatives != null)
			result.runtimeNatives = state.runtimeNatives.copy();
		else if (state.initialized)
			// Import indices are part of the published layout; guessing can patch the wrong slots.
			throw new InternalError("Legacy assembler state lacks native-import ordering; rebuild the baseline");
		result.dispatchNatives = state.dispatchNatives == null ? null : state.dispatchNatives.copy();
		if (state.retiredFields != null)
			for (name in state.retiredFields)
				result.retiredFields.set(name, true);
		for (section in state.sections)
			result.sectionDigests.set(section.path, section.digest);
		if (state.revision < 0
			|| state.publishedInts < 0
			|| state.publishedFloats < 0
			|| state.publishedStrings < 0
			|| state.publishedTypes < 0
			|| state.publishedGlobals != null
			&& state.publishedGlobals < 0
			|| state.publishedInts > result.symbols.ints.length
			|| state.publishedFloats > result.symbols.floats.length
			|| state.publishedStrings > result.symbols.stringCount
			|| state.publishedTypes > result.symbols.types.length
			|| state.publishedGlobals != null
			&& state.publishedGlobals > result.symbols.globalCount
			|| (!state.initialized && state.revision != 0)
			|| (state.initialized && state.revision == 0))
			throw new InternalError("Invalid HashLink assembler baseline");
		result.initialized = state.initialized;
		result.revision = state.revision;
		result.publishedInts = state.publishedInts;
		result.publishedFloats = state.publishedFloats;
		result.publishedStrings = state.publishedStrings;
		result.publishedTypes = state.publishedTypes;
		// A baseline from before literals became globals published every global it had.
		result.publishedGlobals = state.publishedGlobals == null
			? result.symbols.globalCount : state.publishedGlobals;
		return result;
	}

	/** The last revision handed out, by this history or one it continues. */
	public function lastRevision():Int
		return revision > revisionFloor ? revision : revisionFloor;

	/** Numbers this assembler's next build after `revision`, which another history of the same module already used. */
	public function continueRevisions(revision:Int):Void
		if (revision > revisionFloor)
			revisionFloor = revision;

	/**
	 * Renames the running module's lambdas, with their environments, cells and nested lambdas, as `steps` say (see
	 * `LambdaAlignment`): each keeps its slot, stable ID, lowered code and types under its new name, so the build that uses the
	 * new names patches them in place and appends what the names it frees now stand for.
	 */
	public function renameLambdas(steps:Array<NameRewrite>):Void
		for (step in steps) {
			var names:Map<String, String> = [], renames:Array<{from:String, to:String}> = [];
			for (name in cache.slots)
				names.set(name, step.apply(name));
			for (from => to in names)
				if (from != to) {
					renamed.set(to, true);
					renames.push({from: from, to: to});
				}
			cache.rename(names);
			renameLowered(names);
			recordRenames(renames.concat(symbols.renameTypes(step)));
			liveChain++;
			if (programNames != null)
				programNames = step.keys(programNames);
		}

	/**
	 * Records renames made together, as the running module will know them: renames since the last assembly compose, so a
	 * patch, which applies its renames all at once to the running module's names, renames each once.
	 */
	function recordRenames(renames:Array<{from:String, to:String}>):Void {
		var earlier = pendingRenames, composed = [for (rename in earlier) rename], byTarget:Map<String, Int> = [];
		for (index in 0...earlier.length)
			byTarget.set(earlier[index].to, index);
		for (rename in renames) {
			var index = byTarget.get(rename.from);
			if (index == null)
				composed.push(rename);
			else
				composed[index] = {from: earlier[index].from, to: rename.to};
		}
		pendingRenames = [for (rename in composed) if (rename.from != rename.to) rename];
	}

	/**
	 * The functions a rename (`renameLambdas`) gave other names since the last assembly. Their code, and the code that calls
	 * or makes closures of their slots, was lowered against the old names: the next assembly lowers it again, from the IR the
	 * names have now, without patching it into the running module, which keeps its functions in their slots.
	 */
	var renamed:Map<String, Bool> = [];

	/** The functions to lower again after a rename (`renamed`): the renamed ones and those whose code reaches their slots. */
	function afterRenames(present:Map<String, Bool>):Array<String> {
		if (!renamed.keys().hasNext())
			return [];
		var slots:Map<Int, Bool> = [], result:Array<String> = [];
		for (name in renamed.keys()) {
			var lowered = published.entries.get(name);
			if (lowered != null)
				slots.set(lowered.fn.functionIndex, true);
		}
		for (name => entry in published.entries)
			if (present.exists(name) && !RetiredName.is(name)
				&& (renamed.exists(name) || referencesAny(entry.fn, slots)))
				result.push(name);
		result.sort(Reflect.compare);
		renamed = [];
		return result;
	}

	function renameLowered(names:Map<String, String>):Void {
		var renamed:Map<String, HlLoweredFunction> = [];
		for (name => entry in published.entries) {
			var next = names.get(name);
			renamed.set(next == null ? name : next, next == null ? entry : entry.renamed(next));
		}
		published.entries = renamed;
	}

	/**
	 * A function whose signature changed cannot take its slot's new code: closures, and callers this build does not lower
	 * again, call the slot with the old arguments. So it leaves the slot under a retired name, keeping its code for them, and
	 * the function takes a new slot (`RetiredName.movedFunction`). Prototype entries name slots too, so a method an object
	 * dispatches to (`dispatched`, see `PatchPlanner.dispatchedFunctions`) keeps its slot; the plan reloads for those
	 * (`PatchPlanner.plan`). Returns the moved names.
	 */
	function moveChangedSignatures(program:IrProgram, tag:String, dispatched:Map<String, Bool>):SignatureMoves {
		var renames:Map<String, String> = [], moved:Array<String> = [];
		for (fn in program.functions) {
			var known = cache.signatureOf(fn.name);
			// A lambda renamed for this build (`renameLambdas`) still has the signature it was cached with, which names its
			// environment by its old ordinal; the renamed environment keeps its type, so ordinals do not count.
			if (known == null
				|| !cache.userSlots.exists(fn.name)
				|| IrTypeCodec.withoutOrdinals(known) == IrTypeCodec.withoutOrdinals(HlFunctionCache.signature(fn))
				|| !PatchPlanner.movesOnSignatureChange(fn.name, dispatched))
				continue;
			renames.set(fn.name, RetiredName.movedFunction(fn.name, tag));
			moved.push(fn.name);
		}
		var adapted:Array<String> = [],
			guards:Array<{name:String, description:String}> = [];
		if (moved.length == 0)
			return {moved: moved, adapted: adapted, guards: guards};
		cache.rename(renames);
		renameLowered(renames);
		recordRenames([for (name in moved) {from: name, to: renames.get(name)}]);
		// The old slot, and the slots earlier moves left, keep closures the running program made. Each takes an adapter that
		// calls the function's new code with the old arguments (`signatureAdapter`), so they all reach the latest code in one
		// step. A slot no adapter can bridge keeps its old code, and the patch applies only when no stored closure is left to
		// call it.
		var byName:Map<String, IrFunction> = [for (fn in program.functions) fn.name => fn];
		for (name in cache.slots) {
			var from = RetiredName.movedFrom(name);
			if (from == null || !renames.exists(from))
				continue;
			var old = cache.functions.get(name), target = byName.get(from);
			var adapter = old == null
				|| target == null ? null : signatureAdapter(name, old, target, program.parameterDefaults.get(from));
			if (adapter != null) {
				cache.replaceBody(name, adapter);
				adapted.push(name);
			} else
				guards.push({name: name, description: '$from changed signature incompatibly'});
		}
		return {moved: moved, adapted: adapted, guards: guards};
	}

	/**
	 * A function named `name` with the arguments and result of `old` that calls `target`: an argument `target` still takes,
	 * matched by name, is passed on, converted when its type widened (`T` to `Null<T>` or Dynamic); a parameter `target`
	 * added is given its literal default (`defaults`); one it removed is dropped. Null when some argument has no safe value,
	 * a parameter whose type narrowed or that has no literal default, or when the result cannot be converted back.
	 */
	static function signatureAdapter(name:String, old:IrFunction, target:IrFunction,
			defaults:Null<Map<String, IrDefault>>):Null<IrFunction> {
		var builder = new IrBuilder(), given:Map<String, IrValue> = [];
		for (argument in old.arguments)
			given.set(parameterName(argument), builder.argument(argument.name, argument.type));
		var passed:Array<IrValue> = [];
		for (parameter in target.arguments) {
			var name = parameterName(parameter),
				value = given.get(name),
				literal = defaults == null ? null : defaults.get(name);
			var converted = value != null ? widen(builder, value, parameter.type) : literal == null
				? null : defaultValue(builder, literal, parameter.type);
			if (converted == null)
				return null;
			passed.push(converted);
		}
		var result = builder.call(target.name, passed, target.result);
		var returned = sameType(old.result, Void) ? builder.constVoid() : widen(builder, result, old.result);
		if (returned == null)
			return null;
		builder.returnValue(returned);
		return new IrFunction(name, builder.arguments, old.result, builder.blocks, Ordinary, null, false,
			old.retention);
	}

	/** The source name of a function's argument: IR names locals `$l<number>:<name>`. */
	static function parameterName(argument:IrValue):String {
		var name = argument.name;
		return StringTools.startsWith(name, "$l") && name.indexOf(":") > 0 ? name.substr(name.indexOf(":") + 1) : name;
	}

	static function sameType(a:IrType, b:IrType):Bool
		return IrTypeCodec.withoutOrdinals(compiler.ir.model.IrTypeIdentity.text(a))
			== IrTypeCodec.withoutOrdinals(compiler.ir.model.IrTypeIdentity.text(b));

	/** `value` as a `type` that holds every value of its own, or null when `type` does not. */
	static function widen(builder:IrBuilder, value:IrValue, type:IrType):Null<IrValue> {
		if (sameType(value.type, type))
			return value;
		return switch type {
			case Nullable(element) if (sameType(element, value.type)): builder.toDyn(value, type);
			case Dyn if (!sameType(value.type, Void)): builder.toDyn(value);
			default: null;
		};
	}

	/** The literal `value` as a `type` argument, or null when it is not one. */
	static function defaultValue(builder:IrBuilder, value:IrDefault, type:IrType):Null<IrValue> {
		var plain = switch type {
			case Nullable(element): element;
			default: type;
		};
		var made:Null<IrValue> = switch value {
			case NullDefault: switch type {
					case Nullable(_), Dyn, Obj(_): return builder.constNull(type);
					default: null;
				};
			case IntDefault(number): sameType(plain, I32) ? builder.constInt(number) : sameType(plain, F64)
				? builder.constFloat(number) : null;
			case FloatDefault(number): sameType(plain, F64) ? builder.constFloat(number) : null;
			case BoolDefault(flag): sameType(plain, Bool) ? builder.constBool(flag) : null;
		};
		return made == null ? null : widen(builder, made, type);
	}

	/**
	 * The functions the running module has that this build drops, which closures it stored may still call: those the last
	 * program had and `program` lacks, lambdas retired by a rename among them. Retired functions an adapter now serves, functions
	 * moved for a changed signature (`moveChangedSignatures` guards those), and functions still `declared` that the build only
	 * does not reach, whose slots keep their code, are left out.
	 */
	function dropGuards(program:IrProgram, skip:Map<String, Bool>, declared:Map<String, Bool>,
			sources:SourceAnchors):Array<{
				name:String,
				description:String
			}> {
		var present:Map<String, Bool> = [for (fn in program.functions) fn.name => true],
			guards:Array<{name:String, description:String}> = [];
		for (name in cache.slots) {
			if (present.exists(name)
				|| skip.exists(name)
				|| declared.exists(name)
				|| RetiredName.movedFrom(name) != null
				|| name == "__init"
				|| StringTools.endsWith(name, "." + IrProgramAssembler.LIVE_INITIALIZER))
				continue;
			// After a restore nothing says what the last program had, so every function no build has counts as dropped.
			if (programNames != null && !programNames.exists(name))
				continue;
			guards.push({name: name, description: describeDropped(name, cache.functions.get(name), sources)});
		}
		return guards;
	}

	static function describeDropped(name:String, fn:Null<IrFunction>, sources:SourceAnchors):String {
		if (!LambdaName.is(name))
			return '$name was deleted';
		var location = fn == null ? null : firstLocation(fn);
		if (location != null && sources.places(location.anchor))
			return 'a deleted lambda at ${sources.path(location.anchor)}:${sources.line(location.anchor) + location.line}';
		return 'a deleted lambda in ${LambdaName.outermost(name)}';
	}

	/**
	 * Lets the IR of function `name` go, keeping its signature (`HlFunctionCache.vacate`); its lowered code stays, since the
	 * module this assembler writes has it in the slot.
	 */
	function vacate(name:String):Void {
		var vacant = cache.vacate(name), lowered = published.entries.get(name);
		if (vacant != null && lowered != null)
			published.setEntry(name, lowered.from(vacant));
	}

	/**
	 * Where `fn`'s code starts. A cached function is read from its body's rows: decoding its blocks would leave them cached on a
	 * function no build lowers again.
	 */
	static function firstLocation(fn:IrFunction):Null<compiler.ir.model.SourceProvenance.SourceLocation> {
		var body = fn.body;
		if (body != null)
			return body.firstLocation();
		for (block in fn.blocks)
			for (instruction in block.instructions)
				if (instruction.provenance.location != null)
					return instruction.provenance.location;
		return null;
	}

	/**
	 * The functions whose lowered code calls, or makes a closure of, the slot a function in `moved` left (see
	 * `moveChangedSignatures`), retired functions aside. Each is lowered again in the same build, wherever its source is, so
	 * it calls the function's new slot: a caller the edit did not touch, in another file say, would otherwise keep reaching
	 * the code left in the old slot. Removed callers keep their cached code and its old slot, whose adapter preserves
	 * the call for any closures that are still alive; their stale IR cannot be lowered against the new signature.
	 */
	function callersOfMoved(moved:Array<String>, tag:String, present:Map<String, Bool>):Array<String> {
		var oldSlots:Map<Int, Bool> = [];
		for (name in moved) {
			var lowered = published.entries.get(RetiredName.movedFunction(name, tag));
			if (lowered != null)
				oldSlots.set(lowered.fn.functionIndex, true);
		}
		var callers:Array<String> = [];
		for (name => entry in published.entries)
			if (present.exists(name) && !RetiredName.is(name) && referencesAny(entry.fn, oldSlots))
				callers.push(name);
		callers.sort(Reflect.compare);
		return callers;
	}

	static function referencesAny(fn:HlFunction, slots:Map<Int, Bool>):Bool {
		for (opcode in fn.opcodes)
			switch opcode {
				case Call0(_, target) | Call1(_, target, _) | Call2(_, target, _, _) | CallN(_, target,
					_) | StaticClosure(_, target) | InstanceClosure(_, target, _):
					if (slots.exists(target))
						return true;
				default:
			}
		return false;
	}

	/**
	 * Forgets every published symbol index. Interned object types record the slot of each method, so once
	 * the slot layout has moved they would point every method table at a neighbouring function; a module
	 * that cannot be patched must intern its types afresh against the new layout.
	 */
	function discardPublishedSymbols():Void {
		symbols = new HlSymbolTable();
		published = new HlLoweredCache();
		liveChain++;
		publishedInts = 0;
		publishedFloats = 0;
		publishedStrings = 0;
		publishedTypes = 0;
		publishedGlobals = 0;
		retiredFields = [];
	}

	/**
	 * Whether every global `module` has past the published ones is a String constant or the value slot of an object type the
	 * build adds, which are the globals a patch can carry.
	 */
	function addsOnlyPatchableGlobals(module:HlCode):Bool {
		var constants:Map<Int, Bool> = [];
		for (constant in symbols.stringConstantGlobals())
			if (constant.global >= publishedGlobals)
				constants.set(constant.global, true);
		for (global in publishedGlobals...module.globals.length)
			if (!constants.exists(global)
				&& !(module.globals[global] >= publishedTypes && isObjectValueGlobal(module, global)))
				return false;
		return true;
	}

	/** Whether `global` is the value slot of the object or struct type it holds (`HlSymbolTable.internObject`). */
	static function isObjectValueGlobal(code:HlCode, global:Int):Bool
		return switch code.types[code.globals[global]] {
			case Object(_, _, value, _, _, _), Structure(_, value, _, _, _): value == global + 1;
			default: false;
		};

	static function sameNames(previous:Null<Array<String>>, next:Array<String>):Bool {
		if (previous == null || previous.length != next.length)
			return false;
		for (index in 0...next.length)
			if (previous[index] != next[index])
				return false;
		return true;
	}

	/**
	 * Checks the published objects' fields and methods against `program` for a patch, and gives fields added to an object
	 * the object's reserved slots. A patch keeps every published field where it is: one the program no longer has keeps
	 * its slot and is no longer read (it is retired, see `retiredFields`), and a reordered one keeps its slot, so neither
	 * needs anything. Each reason is a change a patch cannot make, for which the assembler publishes a fresh module:
	 *
	 * - a field whose type changed, or an added field when every reserved slot is taken, or one stored inline (a value
	 *   object) or laid out for natives;
	 * - a method the prototype must dispatch to: an added method that overrides one or is overridden, a removed one that
	 *   overrode one, or one the runtime calls by name (`toString` and its kind). An added method that nothing overrides
	 *   gets no prototype slot; calls reach it directly (`HlLower.addedMethodFunction`).
	 *
	 * The ABI plan catches the rest: objects added or removed, changed bases, interfaces or kinds, value objects and
	 * closure environments.
	 *
	 * `program` is this build's IR, not the cache's ordered functions: those keep functions the program no longer has,
	 * such as the initializer of fields an earlier patch added. `slots` is the build's function layout, which places the
	 * migrations.
	 */
	function planObjects(program:IrProgram, slots:Map<String, Int>):ObjectPlan {
		var reasons:Array<AbiChange> = [],
			layout:HlObjectLayout = {fields: [], migrations: []},
			functions:Map<String, Bool> = [for (fn in program.functions) fn.name => true],
			byName:Map<String, IrObject> = [for (object in program.objects) object.name => object],
			valueObjects:Map<String, Bool> = [for (object in program.objects) if (object.isValue) object.name => true], // Runtime natives only reach standard library objects, so the program's own natives name the user's.
			nativeVisible = HlLower.nativeVisibleObjects(program.objects, [program.natives]);
		reserveProgramTypes(program);
		for (object in program.objects) {
			var published = symbols.objectDefinition(object.name);
			if (published == null
				|| object.isValue
				|| StringTools.startsWith(object.name, compiler.semantic.LambdaName.ENVIRONMENT_PREFIX))
				continue;
			switch published.definition {
				case Object(_, _, _, _, methods, _):
					planObjectFields(object, published.index, valueObjects, nativeVisible, layout, reasons);
					planObjectMethods(object, [for (method in methods) symbols.string(method.name)], program.objects,
						byName, reasons);
				default:
					continue;
			}
			var initializer = object.name + "." + IrProgramAssembler.LIVE_INITIALIZER;
			if (functions.exists(initializer) && slots.exists(initializer))
				layout.migrations.push({type: published.index, className: object.name, initializer: initializer});
		}
		// Bases first, so a subclass's initializers see the fields of its base initialized.
		layout.migrations.sort(function(a, b) return baseDepth(a.type) - baseDepth(b.type));
		return {reasons: reasons, layout: layout.fields.length > 0 || layout.migrations.length > 0 ? layout : null};
	}

	/**
	 * Reserves the types the program has, as lowering does and in its order: an added field can have a type the same patch
	 * adds (a new class), which needs an index before the type is laid out.
	 */
	function reserveProgramTypes(program:IrProgram):Void {
		for (enumDecl in program.enums)
			symbols.reserveEnum(enumDecl);
		for (interfaceDecl in program.interfaces)
			symbols.reserveInterface(interfaceDecl.name);
		for (object in program.objects)
			symbols.reserveObject(object.name);
	}

	/**
	 * Gives the fields `object` adds a reserved slot of its published type `type`, and records which of its published fields
	 * the program no longer has (`retiredFields`). A field it has again keeps its slot and is no longer retired.
	 */
	function planObjectFields(object:IrObject, type:Int, valueObjects:Map<String, Bool>,
			nativeVisible:Map<String, Bool>, layout:HlObjectLayout,
			reasons:Array<AbiChange>):Void {
		var native = object.nativeLayout != null || nativeVisible.exists(object.name),
			exhausted = false,
			present:Map<String, Bool> = [];
		for (field in object.fields) {
			present.set(field.name, true);
			if (field.nativeLayout != null || field.scalarStorage != null)
				native = true;
		}
		for (field in ownFields(type))
			if (!symbols.isReservedField(field)) {
				var name = symbols.string(field.name);
				if (present.exists(name))
					retiredFields.remove(object.name + "." + name);
				else
					retiredFields.set(object.name + "." + name, true);
			}
		for (field in object.fields) {
			var fieldType = symbols.internObjectFieldType(field.type, valueObjects,
				compiler.ir.model.IrFieldStorage.scalar(field)),
				slot = -1,
				own = ownFields(type);
			for (index in 0...own.length)
				if (symbols.string(own[index].name) == field.name)
					slot = index;
			if (slot >= 0) {
				if (own[slot].type != fieldType)
					reasons.push(ObjectFieldTypeChanged(object.name + "." + field.name));
				continue;
			}
			var stored = switch symbols.types[fieldType] {
				case Parameterized(kind, _): kind == compiler.hl.HlType.Packed;
				default: false;
			};
			if (native || stored) {
				reasons.push(ObjectLayoutChanged(object.name));
				continue;
			}
			if (exhausted)
				continue;
			var assigned = symbols.assignReservedField(object.name, field.name, fieldType);
			if (assigned < 0) {
				exhausted = true;
				reasons.push(ObjectFieldReserveExhausted(object.name));
				continue;
			}
			layout.fields.push(object.name + "." + field.name);
		}
	}

	/** The fields the published object type `type` declares itself, as its definition has them now. */
	function ownFields(type:Int):Array<compiler.hl.HlCode.HlObjectField>
		return switch symbols.types[type] {
			case Object(_, _, _, own, _, _): own;
			default: [];
		};

	/** Checks the methods `object` adds or removes against the ones its published type has (`published`). */
	function planObjectMethods(object:IrObject, published:Array<String>, objects:Array<IrObject>,
			byName:Map<String, IrObject>, reasons:Array<AbiChange>):Void {
		var inherited = object.base == null ? null : symbols.objectMethodSlots(Std.string(object.base));
		for (method in object.methods) {
			if (published.indexOf(method.name) >= 0)
				continue;
			var dispatched = runtimeMethods.indexOf(method.name) >= 0 || inherited != null
				&& inherited.exists(method.name);
			if (!dispatched)
				for (other in objects)
					if (other != object && extendsObject(byName, other, object.name))
						for (overriding in other.methods)
							if (overriding.name == method.name)
								dispatched = true;
			if (dispatched)
				reasons.push(ObjectMethodDispatchChanged(object.name + "." + method.name));
		}
		for (name in published) {
			var kept = false;
			for (method in object.methods)
				if (method.name == name)
					kept = true;
			if (!kept && inherited != null && inherited.exists(name))
				reasons.push(ObjectMethodDispatchChanged(object.name + "." + name));
		}
	}

	/** Whether `object` extends the object named `base`, directly or through other bases of `byName`. */
	static function extendsObject(byName:Map<String, IrObject>, object:IrObject, base:String):Bool {
		var current = object;
		while (current != null && current.base != null) {
			var parent = Std.string(current.base);
			if (parent == base)
				return true;
			current = byName.get(parent);
		}
		return false;
	}

	/** How many bases the published object type `type` has. */
	function baseDepth(type:Int):Int {
		var result = 0, current = type, searching = true;
		while (searching) {
			searching = false;
			switch symbols.types[current] {
				case Object(_, base, _, _, _, _):
					if (base >= 0) {
						result++;
						current = base;
						searching = true;
					}
				default:
			}
		}
		return result;
	}

	/**
	 * The stubs of `program` (`IrProgram.stubbedFunctions`) whose slot holds real code of the same signature: a method the build no
	 * longer reaches keeps the code it last had, as the published set only grows within a module identity, for the instances the
	 * running program made before (docs/design/LIVE_PRUNING.md).
	 */
	function retainedCode(program:IrProgram):Array<IrFunction> {
		var stubbed = program.stubbedFunctions;
		return [
			for (fn in program.functions)
				if (stubbed.exists(fn.name) && cache.userSlots.exists(fn.name) && !stubs.exists(fn.name)
				&& cache.signatureOf(fn.name) == HlFunctionCache.signature(fn)) fn
		];
	}

	/**
	 * The functions of `program` the module has code for that is not theirs: a stub a reached method replaces, or the code of one
	 * the last build did not reach, which edits since may have changed. Lowering trusts the rest.
	 */
	function enteringReach(program:IrProgram):Array<String> {
		var stubbed = program.stubbedFunctions, result:Array<String> = [];
		for (fn in program.functions) {
			if (!cache.userSlots.exists(fn.name) || stubbed.exists(fn.name))
				continue;
			if (stubs.exists(fn.name))
				result.push(fn.name);
			else if (programNames == null || !programNames.exists(fn.name)) {
				var held = cache.functions.get(fn.name);
				if (held == null || held != fn && !compiler.ir.codec.IrFunctionStateEquality.same(held, fn))
					result.push(fn.name);
			}
		}
		return result;
	}

	/** Records which of `functions`, now in the cache, are declaration stubs (`stubs`). */
	function noteStubs(functions:Array<IrFunction>, stubbed:Map<String, Bool>):Void
		for (fn in functions)
			if (stubbed.exists(fn.name))
				stubs.set(fn.name, true);
			else
				stubs.remove(fn.name);

	/** Of the regenerated functions, those that differ from their form in the resumed module, or that it does not have. */
	static function changedSinceResumed(regenerated:Array<String>, program:IrProgram,
			resumed:Map<String, haxe.io.Bytes>):Array<String> {
		var current:Map<String, IrFunction> = [for (fn in program.functions) fn.name => fn];
		return [for (name in regenerated) {
			var old = resumed.get(name), next = current.get(name);
			if (old == null || next == null
				|| old.compare(compiler.ir.codec.IrFunctionStateCodec.encode(next)) != 0) name;
		}];
	}

	/**
	 * `dispatched`: the functions object prototypes dispatch to (`PatchPlanner.dispatchedFunctions`), which keep their slots
	 * when their signatures change; described from `program` when not given. `resumed`: the functions of the module a session resumed
	 * from (`SessionState.rehydrationBaseline`), encoded as this assembler's cache held them; a regenerated function equal to its
	 * resumed form is not a change.
	 */
	public function assemble(program:IrProgram, regenerated:Array<String>, decision:PatchDecision,
			?dispatched:Map<String, Bool>, ?resumed:Map<String, haxe.io.Bytes>):HlAssemblyResult {
		var startedAt = Sys.time() * 1000.0, sources = this.sources ?? new SourceAnchors([]);
		// Runtime calls the lowering writes a fast path for go through one helper each (`IrSharedRuntimeCalls`); a helper this module
		// has not published yet is new code, which a patch must carry. A function that is the same object keeps the form the last
		// build gave it, so the states a live session keeps to take back share it instead of each holding its own.
		var kept = livePatching ? published : loweredCache;
		var shared = compiler.hl.IrSharedRuntimeCalls.apply(program, kept == null ? null : kept.sharedCalls),
			slotted:Map<String, Bool> = [for (name in cache.slots) name => true];
		program = shared.program;
		var reload = switch decision {
			case Patch: false;
			case ReloadDomain(_): true;
			case Reject(diagnostics): throw new InternalError(diagnostics.join("; "));
		};
		var live = livePatching && initialized && !reload,
			retained = live ? retainedCode(program) : [];
		if (retained.length > 0) {
			var withheld:Map<String, Bool> = [for (fn in retained) fn.name => true];
			program = program.copy();
			program.functions = [for (fn in program.functions) if (!withheld.exists(fn.name)) fn];
		}
		// The cache holds each function as this rewrite left it, so a resumed function is compared in that form.
		regenerated = resumed == null ? regenerated.copy() : changedSinceResumed(regenerated, program, resumed);
		if (live) {
			// A function the build does not reach keeps its slot and its code: it is not lowered again, whatever was regenerated.
			var reached:Map<String, Bool> = [for (fn in program.functions) fn.name => true];
			regenerated = [for (name in regenerated) if (reached.exists(name)) name];
			var listedRegenerated:Map<String, Bool> = [for (name in regenerated) name => true];
			for (name in enteringReach(program))
				if (!listedRegenerated.exists(name))
					regenerated.push(name);
		}
		for (name in shared.helpers)
			if (!slotted.exists(name) && regenerated.indexOf(name) < 0)
				regenerated.push(name);
		var guards:Array<{name:String, description:String}> = [];
		if (initialized && !reload) {
			var tag = Std.string(lastRevision() + 1);
			var moves = moveChangedSignatures(program, tag,
				dispatched != null ? dispatched : PatchPlanner.dispatchedFunctions(null,
				compiler.abi.RuntimeAbi.describe(program)));
			var listed:Map<String, Bool> = [for (name in regenerated) name => true];
			function regenerate(name:String):Void
				if (!listed.exists(name)) {
					listed.set(name, true);
					regenerated.push(name);
				}
			regenerated = regenerated.copy();
			for (name in moves.moved)
				regenerate(name);
			for (name in moves.adapted)
				regenerate(name);
			if (moves.moved.length > 0)
				for (name in callersOfMoved(moves.moved, tag, [for (fn in program.functions) fn.name => true]))
					regenerate(name);
			var declared:Map<String, Bool> = [for (name in program.prunedFunctions.keys()) name => true];
			for (fn in retained)
				declared.set(fn.name, true);
			guards = moves.guards.concat(dropGuards(program, [for (name in moves.adapted) name => true], declared,
				sources));
		}
		// Once this patch applies, no closure the running module holds reaches a guard: the runtime refuses the patch while one
		// does, and the new code calls none. So a guard keeps its slot, stable ID, signature and the code the module has in the
		// slot, but not its IR.
		for (guard in guards)
			vacate(guard.name);
		var publishedSlots = cache.slots.length;
		cache.update(program.functions);
		noteStubs(program.functions, program.stubbedFunctions);
		var ordered = new IrProgram(program.entryPoint);
		ordered.natives = program.natives;
		ordered.cNatives = program.cNatives;
		ordered.objects = program.objects;
		ordered.interfaces = program.interfaces;
		ordered.enums = program.enums;
		ordered.staticFields = program.staticFields;
		ordered.functions = cache.ordered();
		// A fresh module needs no retired function (see `moveChangedSignatures` and `renameLambdas`), and no function this
		// program dropped (`dropGuards`): only closures of the running module call them. Lowering their stale code again could
		// fail, as it names functions whose signatures changed and objects this program no longer has (a dropped lambda's
		// environment).
		var present:Map<String, Bool> = [for (fn in program.functions) fn.name => true];
		function startFresh():Void {
			discardPublishedSymbols();
			// A fresh module keeps nothing of the running one's code: the stubs withheld for it are the functions' code again.
			if (retained.length > 0) {
				cache.update(retained);
				noteStubs(retained, program.stubbedFunctions);
				for (fn in retained)
					present.set(fn.name, true);
				retained = [];
			}
			cache.dropRetired(function(name) return RetiredName.is(name) || !present.exists(name));
			ordered.functions = cache.ordered();
		}
		var reuseLowered = initialized && !reload;
		var layoutReasons:Array<String> = [];
		// A domain reload rediscovers native imports without preserving their old slots.
		// Cached object prototypes contain absolute function indices, just like opcodes.
		if (initialized && reload)
			startFresh();
		var cachePreparedAt = Sys.time() * 1000.0;
		var previousNatives = runtimeNatives;
		var nativeUses = loweredCache == null ? null : loweredCache.summaries.natives;
		runtimeNatives = HlLower.discoverRuntimeNatives(ordered, reuseLowered && previousNatives.length > 0
			? previousNatives : null, reuseLowered && previousNatives.length > 0 ? regenerated : null, nativeUses);
		// New runtime imports shift every function slot. Publish a fresh module,
		// never reuse opcodes or patch a live module with the old slot layout.
		if (reuseLowered && runtimeNatives.length != previousNatives.length) {
			reload = true;
			var known = [for (native in previousNatives) native.name => true];
			layoutReasons.push('runtime natives added: '
				+ [for (native in runtimeNatives) if (!known.exists(native.name)) native.name].join(", "));
			reuseLowered = false;
			startFresh();
			runtimeNatives = HlLower.discoverRuntimeNatives(ordered, null, null, nativeUses);
		}
		// C dispatch natives sit with the runtime natives, before every function slot. When they change, every function slot
		// moves, so publish a fresh module.
		var nextDispatch = [for (native in HlLower.discoverCDispatchNatives(ordered)) native.name];
		if (reuseLowered && !sameNames(dispatchNatives, nextDispatch)) {
			reload = true;
			layoutReasons.push("dispatch natives");
			reuseLowered = false;
			startFresh();
			runtimeNatives = HlLower.discoverRuntimeNatives(ordered, null, null, nativeUses);
		}
		dispatchNatives = nextDispatch;
		function slotLayout():Map<String, Int> {
			var result:Map<String, Int> = [], next = 0;
			for (native in runtimeNatives)
				result.set(native.name, next++);
			for (name in nextDispatch)
				result.set(name, next++);
			for (name in cache.slots)
				result.set(name, next++);
			return result;
		}
		var layout = slotLayout();
		if (reuseLowered)
			for (fn in ordered.functions) {
				var previous = published.entries.get(fn.name);
				if (previous != null && previous.fn.functionIndex != layout.get(fn.name)) {
					reload = true;
					layoutReasons.push('slot of ${fn.name} moved from ${previous.fn.functionIndex} to ${layout.get(fn.name)}');
					reuseLowered = false;
					startFresh();
					layout = slotLayout();
					break;
				}
			}
		var objectReasons:Array<AbiChange> = [],
			objectLayout:Null<HlObjectLayout> = null;
		if (reuseLowered) {
			var planned = planObjects(program, layout);
			if (planned.reasons.length > 0) {
				reload = true;
				objectReasons = planned.reasons;
				reuseLowered = false;
				startFresh();
				layout = slotLayout();
			} else
				objectLayout = planned.layout;
		}
		var changed:Array<String> = [];
		if (initialized)
			for (name in regenerated)
				if (cache.userSlots.exists(name) && layout.exists(name))
					changed.push(name);
		changed.sort(Reflect.compare);
		var addsFunctions = initialized && !reload && cache.slots.length > publishedSlots;
		if (livePatching == (loweredCache != null))
			throw new InternalError('a ${livePatching ? "live" : "plain"} build must use ${livePatching ? "only" : "a"} ${livePatching ? "the published functions" : "lowered cache"}');
		var liveCache = loweredCache;
		if (keepsProgram)
			lastProgram = ordered;
		if (livePatching) {
			if (!reuseLowered) {
				published = new HlLoweredCache();
				liveChain++;
			}
			liveCache = published;
		}
		var relowered = regenerated.copy(), listedForLowering = [for (name in regenerated) name => true];
		for (name in afterRenames(present))
			if (!listedForLowering.exists(name))
				relowered.push(name);
		var lowered = HlLower.lowerStableMeasured(ordered, symbols, layout, relowered, runtimeNatives, fieldReserve,
			developmentMetadata,
			livePatching || keepsLowered ? liveCache : null, irVerified,
			livePatching,
			name -> RetiredName.is(name) || !present.exists(name), checkReuse, sources, liveChain),
			module = lowered.code;
		reusedFunctions = lowered.reusedFunctions;
		movedFunctions = lowered.movedFunctions;
		var loweredAt = Sys.time() * 1000.0;
		// A running module can take new String constants and the value slots of new object types but no other global, so a
		// build that adds any other publishes a fresh module. The ABI plan already asks for that when a static field is added; this guards the rest.
		if (initialized && !reload && !addsOnlyPatchableGlobals(module)) {
			reload = true;
			layoutReasons.push('globals $publishedGlobals -> ${module.globals.length} add more than String constants and new types');
		}
		var baseInts = publishedInts,
			baseFloats = publishedFloats,
			baseStrings = publishedStrings,
			baseTypes = publishedTypes,
			baseGlobals = publishedGlobals;
		publishedInts = module.ints.length;
		publishedFloats = module.floats.length;
		publishedStrings = module.strings.length;
		publishedTypes = module.types.length;
		publishedGlobals = module.globals.length;
		// A build that changes nothing the running module holds (a resumed session warming up, a save that only touched
		// what lowering ignores) is the published revision again: a new revision would carry no patch, and the runtime
		// can only reach a revision without a patch by reloading.
		var baseRevision = revision;
		programNames = [for (name in present.keys()) name => true];
		var renames = reload ? [] : pendingRenames;
		pendingRenames = [];
		var unchanged = initialized && !reload && changed.length == 0 && !addsFunctions
			&& objectLayout == null && baseInts == publishedInts
			&& baseFloats == publishedFloats && baseStrings == publishedStrings && baseTypes == publishedTypes
			&& baseGlobals == publishedGlobals;
		if (!unchanged)
			revision = lastRevision() + 1;
		initialized = true;
		return {
			module: module,
			unchanged: unchanged,
			baseRevision: baseRevision,
			changedFunctions: changed,
			guards: reload ? [] : guards,
			renames: renames,
			functionIndices: layout,
			requiresReload: reload,
			layoutReasons: layoutReasons,
			objectReasons: objectReasons,
			objectLayout: reload ? null : objectLayout,
			revision: revision,
			cachePreparationMs: cachePreparedAt - startedAt,
			loweringMs: loweredAt - cachePreparedAt,
			publicationMs: Sys.time() * 1000.0 - loweredAt,
			verificationMs: lowered.metrics.verificationMs,
			metadataMs: lowered.metrics.metadataMs,
			functionLoweringMs: lowered.metrics.functionsMs,
			debugAssemblyMs: lowered.metrics.debugMs,
			lowerFinalizationMs: lowered.metrics.finalizationMs,
			allocationPhases: lowered.metrics.allocationPhases
		};
	}
}
