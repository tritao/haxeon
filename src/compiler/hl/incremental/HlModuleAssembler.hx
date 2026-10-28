package compiler.hl.incremental;

import compiler.ir.hl.HlLower;
import compiler.ir.Ir.IrProgram;
import compiler.abi.LambdaAlignment;
import compiler.ir.codec.IrTypeCodec;
import compiler.abi.LambdaAlignment.NameRewrite;
import compiler.abi.PatchPlanner;
import compiler.abi.PatchPlanner.AbiChange;
import compiler.abi.PatchPlanner.PatchDecision;
import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.patch.HlPatchWriter.HlLayoutPatch;
import compiler.ir.Ir.IrObject;
import compiler.hl.HlCode;
import compiler.hl.HlFunction;
import compiler.hl.persistence.HlFunctionCacheStateCodec;
import compiler.hl.persistence.HlSymbolStateCodec;
import compiler.hl.patch.HlPatchWriter;
import compiler.ir.Ir.IrNative;
import compiler.ir.hl.HlDebugMetadataCache;
import compiler.compilation.AllocationMeter.PhaseAllocation;

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
}

/**
 * Fields a build gives existing objects in their reserved slots, with the definitions the running module has for those
 * objects; `migrations` name the function that initializes each object's added fields.
 */
typedef HlObjectLayout = {
	fields:Array<{type:Int, field:Int, name:Int, fieldType:Int}>,
	previousTypes:Map<Int, HlTypeDef>,
	migrations:Array<{type:Int, functionName:String}>
}

/** Module plus identity and delta metadata produced by one assembly transaction. */
typedef HlAssemblyResult = {
	final module:HlCode;
	final changedFunctions:Array<Int>;
	final changedSlots:Array<Int>;

	/** Slots this build gives functions the published module does not have, in slot order, with their names. */
	final addedFunctions:Array<{slot:Int, name:String}>;

	final functionIndices:Map<String, Int>;
	final requiresReload:Bool;

	/** The revision a patch of this build applies to: the one the assembler's published state had before it. */
	final baseRevision:Int;

	/** Why the assembler published a fresh module on its own, beyond the ABI plan's reasons. */
	final layoutReasons:Array<String>;

	/** Object changes the running module cannot take, which made the assembler publish a fresh module. */
	final objectReasons:Array<AbiChange>;

	/** The object fields this build adds to the running module, null without any. */
	final objectLayout:Null<HlObjectLayout>;
	final revision:Int;
	final baseInts:Int;
	final baseFloats:Int;
	final baseStrings:Int;
	final baseTypes:Int;

	/** Globals the running module has, which a patch's new literal globals follow. */
	final baseGlobals:Int;

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
	var loweredFunctions:Map<String, HlFunction> = [];
	var runtimeNatives:Array<IrNative> = [];

	/** Null when a restored baseline does not record them, so the next build cannot trust their slots. */
	var dispatchNatives:Null<Array<String>> = [];

	final debugMetadata:HlDebugMetadataCache;

	/**
	 * Reserved slots each object gets when this assembler lays out a fresh module (see `HlLower.reservedSlots`): the
	 * fields live patches can add to it. Zero without live patching.
	 */
	public var fieldReserve:Int = 0;

	/** The function a live build adds to initialize an object's added fields on existing instances (see `IrProgramAssembler`). */
	public static inline final LIVE_INITIALIZER = "__liveinit";

	/** Methods HashLink's runtime finds by name in the prototype, which a direct call cannot stand in for. */
	static final runtimeMethods:Array<String> = ["__string", "__compare", "__cast", "__get_field"];

	public function new(?stableIds:Map<String, Int>, ?sharedDebugMetadata:HlDebugMetadataCache) {
		cache = new HlFunctionCache(stableIds);
		debugMetadata = sharedDebugMetadata == null ? new HlDebugMetadataCache() : sharedDebugMetadata;
	}

	public function copy():HlModuleAssembler {
		var result = new HlModuleAssembler(null, debugMetadata);
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
		result.loweredFunctions = [for (name => fn in loweredFunctions) name => fn];
		result.runtimeNatives = runtimeNatives.copy();
		result.dispatchNatives = dispatchNatives == null ? null : dispatchNatives.copy();
		result.fieldReserve = fieldReserve;
		return result;
	}

	/** Whether this assembler has published a module, so an object it published can take added fields. */
	public function isPublished():Bool
		return initialized;

	/**
	 * Whether object `objectName` has a field `fieldName` in the module this assembler published. False for an object it
	 * has not published: the object is new, and nothing needs its fields initialized.
	 */
	public function publishedField(objectName:String, fieldName:String):Bool
		return initialized && symbols.objectFieldIndex(objectName, fieldName) != null;

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
			dispatchNatives: dispatchNatives == null ? null : dispatchNatives.copy()
		};

	public static function fromState(state:HlAssemblerState):HlModuleAssembler {
		var result = new HlModuleAssembler();
		result.symbols = HlSymbolStateCodec.restore(state.symbols);
		result.cache = HlFunctionCacheStateCodec.restore(state.cache);
		if (state.runtimeNatives != null)
			result.runtimeNatives = state.runtimeNatives.copy();
		else if (state.initialized)
			// Import indices are part of the published layout; guessing can patch the wrong slots.
			throw "Legacy assembler state lacks native-import ordering; rebuild the baseline";
		result.dispatchNatives = state.dispatchNatives == null ? null : state.dispatchNatives.copy();
		if (state.revision < 0
			|| state.publishedInts < 0
			|| state.publishedFloats < 0
			|| state.publishedStrings < 0
			|| state.publishedTypes < 0
			|| state.publishedGlobals != null
			&& state.publishedGlobals < 0
			|| state.publishedInts > result.symbols.ints.length
			|| state.publishedFloats > result.symbols.floats.length
			|| state.publishedStrings > result.symbols.strings.length
			|| state.publishedTypes > result.symbols.types.length
			|| state.publishedGlobals != null
			&& state.publishedGlobals > result.symbols.globals.length
			|| (!state.initialized && state.revision != 0)
			|| (state.initialized && state.revision == 0))
			throw "Invalid HashLink assembler baseline";
		result.initialized = state.initialized;
		result.revision = state.revision;
		result.publishedInts = state.publishedInts;
		result.publishedFloats = state.publishedFloats;
		result.publishedStrings = state.publishedStrings;
		result.publishedTypes = state.publishedTypes;
		// A baseline from before literals became globals published every global it had.
		result.publishedGlobals = state.publishedGlobals == null ? result.symbols.globals.length : state.publishedGlobals;
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
			var names:Map<String, String> = [];
			for (name in cache.slots)
				names.set(name, step.apply(name));
			for (name in cache.stableIds.keys())
				names.set(name, step.apply(name));
			cache.rename(names);
			renameLowered(names);
			symbols.renameTypes(step);
		}

	function renameLowered(names:Map<String, String>):Void {
		var renamed:Map<String, HlFunction> = [];
		for (name => fn in loweredFunctions) {
			var next = names.get(name);
			renamed.set(next == null ? name : next, fn);
		}
		loweredFunctions = renamed;
	}

	/**
	 * A function whose signature changed cannot take its slot's new code: closures, and callers this build does not lower
	 * again, call the slot with the old arguments. So it leaves the slot under a retired name, keeping its code for them, and
	 * the function takes a new slot (`LambdaAlignment.retiredFunctionName`). Prototype entries name slots too, so a method an
	 * object dispatches to keeps its slot; the plan reloads for those (`PatchPlanner.plan`). Returns the moved names.
	 */
	function moveChangedSignatures(program:IrProgram, tag:String):Array<String> {
		var dispatched:Map<String, Bool> = [], renames:Map<String, String> = [], moved:Array<String> = [];
		for (object in program.objects)
			for (method in object.methods)
				dispatched.set(method.functionName, true);
		for (fn in program.functions) {
			var known = cache.signatures.get(fn.name);
			// A lambda renamed for this build (`renameLambdas`) still has the signature it was cached with, which names its
			// environment by its old ordinal; the renamed environment keeps its type, so ordinals do not count.
			if (known == null || !cache.userSlots.exists(fn.name)
				|| IrTypeCodec.withoutOrdinals(known) == IrTypeCodec.withoutOrdinals(HlFunctionCache.signature(fn))
				|| !PatchPlanner.movesOnSignatureChange(fn.name, dispatched))
				continue;
			renames.set(fn.name, LambdaAlignment.retiredFunctionName(fn.name, tag));
			moved.push(fn.name);
		}
		if (moved.length > 0) {
			cache.rename(renames);
			renameLowered(renames);
		}
		return moved;
	}

	/**
	 * Forgets every published symbol index. Interned object types record the slot of each method, so once
	 * the slot layout has moved they would point every method table at a neighbouring function; a module
	 * that cannot be patched must intern its types afresh against the new layout.
	 */
	function discardPublishedSymbols():Void {
		symbols = new HlSymbolTable();
		loweredFunctions = [];
		publishedInts = 0;
		publishedFloats = 0;
		publishedStrings = 0;
		publishedTypes = 0;
		publishedGlobals = 0;
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
			if (!constants.exists(global) && !(module.globals[global] >= publishedTypes && HlPatchWriter.isObjectValueGlobal(module, global)))
				return false;
		return true;
	}

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
	 * its slot and is no longer read, and a reordered one keeps its slot, so neither needs anything. Each reason is a
	 * change a patch cannot make, for which the assembler publishes a fresh module:
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
	 * such as the initializer of fields an earlier patch added.
	 */
	function planObjects(program:IrProgram):{
		reasons:Array<AbiChange>,
		fields:Array<{type:Int, field:Int, name:Int, fieldType:Int}>,
		previousTypes:Map<Int, HlTypeDef>,
		migrations:Array<{type:Int, functionName:String}>
	} {
		var reasons:Array<AbiChange> = [],
			fields:Array<{type:Int, field:Int, name:Int, fieldType:Int}> = [],
			previousTypes:Map<Int, HlTypeDef> = [],
			migrations:Array<{type:Int, functionName:String}> = [],
			byName:Map<String, IrObject> = [],
			valueObjects:Map<String, Bool> = [],
			functions:Map<String, Bool> = [for (fn in program.functions) fn.name => true],
			// Runtime natives only reach standard library objects, so the program's own natives name the user's.
			nativeVisible = compiler.ir.hl.HlLower.nativeVisibleObjects(program.objects, [program.natives]);
		// An added field can have a type the same patch adds (a new class); reserve the new types as lowering does, in its
		// order, so the field's type has an index before the type is laid out.
		for (enumDecl in program.enums)
			symbols.reserveEnum(enumDecl.name);
		for (interfaceDecl in program.interfaces)
			symbols.reserveInterface(interfaceDecl.name);
		for (object in program.objects)
			symbols.reserveObject(object.name);
		for (object in program.objects) {
			byName.set(object.name, object);
			if (object.isValue)
				valueObjects.set(object.name, true);
		}
		function extendsObject(name:String, base:String):Bool {
			var current = byName.get(name);
			while (current != null && current.base != null) {
				var parent = Std.string(current.base);
				if (parent == base)
					return true;
				current = byName.get(parent);
			}
			return false;
		}
		for (object in program.objects) {
			var published = symbols.objectDefinition(object.name);
			if (published == null || object.isValue || StringTools.startsWith(object.name, "$lambda-env:"))
				continue;
			var ownFields:Array<compiler.hl.HlCode.HlObjectField> = [], ownMethods:Array<String> = [];
			switch published.definition {
				case Object(_, _, _, own, methods, _):
					ownFields = own;
					for (method in methods)
						ownMethods.push(symbols.strings[method.name]);
				default:
					continue;
			}
			var native = object.nativeLayout != null || nativeVisible.exists(object.name), exhausted = false;
			for (field in object.fields)
				if (field.nativeLayout != null)
					native = true;
			for (field in object.fields) {
				var type = symbols.internObjectFieldType(field.type, valueObjects, field.nativeLayout), slot = -1;
				for (index in 0...ownFields.length)
					if (symbols.strings[ownFields[index].name] == field.name)
						slot = index;
				if (slot >= 0) {
					if (ownFields[slot].type != type)
						reasons.push(ObjectFieldTypeChanged(object.name + "." + field.name));
					continue;
				}
				var stored = switch symbols.types[type] {
					case Parameterized(kind, _): kind == compiler.hl.HlType.Packed;
					default: false;
				};
				if (native || stored) {
					reasons.push(ObjectLayoutChanged(object.name));
					continue;
				}
				if (exhausted)
					continue;
				var previous = symbols.types[published.index];
				var assigned = symbols.assignReservedField(object.name, field.name, type);
				if (assigned < 0) {
					exhausted = true;
					reasons.push(ObjectFieldReserveExhausted(object.name));
					continue;
				}
				if (!previousTypes.exists(published.index))
					previousTypes.set(published.index, previous);
				fields.push({type: published.index, field: assigned, name: symbols.internString(field.name), fieldType: type});
				// The definition changed, so read the slots again for the next added field.
				switch symbols.types[published.index] {
					case Object(_, _, _, own, _, _):
						ownFields = own;
					default:
				}
			}
			var inherited = object.base == null ? null : symbols.objectMethodSlots(Std.string(object.base));
			for (method in object.methods) {
				if (ownMethods.indexOf(method.name) >= 0)
					continue;
				var dispatched = runtimeMethods.indexOf(method.name) >= 0 || inherited != null && inherited.exists(method.name);
				if (!dispatched)
					for (other in program.objects)
						if (other != object && extendsObject(other.name, object.name))
							for (overriding in other.methods)
								if (overriding.name == method.name)
									dispatched = true;
				if (dispatched)
					reasons.push(ObjectMethodDispatchChanged(object.name + "." + method.name));
			}
			for (name in ownMethods) {
				var kept = false;
				for (method in object.methods)
					if (method.name == name)
						kept = true;
				if (!kept && inherited != null && inherited.exists(name))
					reasons.push(ObjectMethodDispatchChanged(object.name + "." + name));
			}
			var initializer = object.name + "." + LIVE_INITIALIZER;
			if (functions.exists(initializer))
				migrations.push({type: published.index, functionName: initializer});
		}
		// Bases first, so a subclass's initializers see the fields of its base initialized.
		function depth(type:Int):Int {
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
		migrations.sort(function(a, b) return depth(a.type) - depth(b.type));
		return {reasons: reasons, fields: fields, previousTypes: previousTypes, migrations: migrations};
	}

	public function assemble(program:IrProgram, regenerated:Array<String>, decision:PatchDecision, ?relocated:Array<String>):HlAssemblyResult {
		var startedAt = Sys.time() * 1000.0;
		var reload = switch decision {
			case Patch: false;
			case ReloadDomain(_): true;
			case Reject(diagnostics): throw diagnostics.join("; ");
		};
		if (initialized && !reload) {
			var moved = moveChangedSignatures(program, Std.string(lastRevision() + 1));
			if (moved.length > 0) {
				var listed:Map<String, Bool> = [for (name in regenerated) name => true];
				regenerated = regenerated.concat([for (name in moved) if (!listed.exists(name)) name]);
			}
		}
		var publishedSlots = cache.slots.length;
		cache.update(program.functions);
		var ordered = new IrProgram(program.entryPoint);
		ordered.natives = program.natives;
		ordered.cNatives = program.cNatives;
		ordered.objects = program.objects;
		ordered.interfaces = program.interfaces;
		ordered.enums = program.enums;
		ordered.staticFields = program.staticFields;
		ordered.functions = cache.ordered();
		// A fresh module needs no retired function (see `moveChangedSignatures` and `renameLambdas`): only closures of the
		// running module call them. Lowering their stale code again could fail, as it names functions whose signatures changed.
		function startFresh():Void {
			discardPublishedSymbols();
			if (cache.dropRetired(LambdaAlignment.isRetired))
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
		runtimeNatives = HlLower.discoverRuntimeNatives(ordered, reuseLowered && previousNatives.length > 0 ? previousNatives : null, reuseLowered && previousNatives.length > 0 ? regenerated : null);
		// New runtime imports shift every function slot. Publish a fresh module,
		// never reuse opcodes or patch a live module with the old slot layout.
		if (reuseLowered && runtimeNatives.length != previousNatives.length) {
			reload = true;
			var known = [for (native in previousNatives) native.name => true];
			layoutReasons.push('runtime natives added: ' + [for (native in runtimeNatives) if (!known.exists(native.name)) native.name].join(", "));
			reuseLowered = false;
			startFresh();
			runtimeNatives = HlLower.discoverRuntimeNatives(ordered);
		}
		// C dispatch natives sit with the runtime natives, before every function slot. When they change, every function slot
		// moves, so publish a fresh module.
		var nextDispatch = [for (native in HlLower.discoverCDispatchNatives(ordered)) native.name];
		if (reuseLowered && !sameNames(dispatchNatives, nextDispatch)) {
			reload = true;
			layoutReasons.push("dispatch natives");
			reuseLowered = false;
			startFresh();
			runtimeNatives = HlLower.discoverRuntimeNatives(ordered);
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
				var previous = loweredFunctions.get(fn.name);
				if (previous != null && previous.functionIndex != layout.get(fn.name)) {
					reload = true;
					layoutReasons.push('slot of ${fn.name} moved from ${previous.functionIndex} to ${layout.get(fn.name)}');
					reuseLowered = false;
					startFresh();
					layout = slotLayout();
					break;
				}
			}
		var objectReasons:Array<AbiChange> = [], objectLayout:Null<HlObjectLayout> = null;
		if (reuseLowered) {
			var planned = planObjects(program);
			if (planned.reasons.length > 0) {
				reload = true;
				objectReasons = planned.reasons;
				reuseLowered = false;
				startFresh();
				layout = slotLayout();
			} else if (planned.fields.length > 0 || planned.migrations.length > 0)
				objectLayout = {fields: planned.fields, previousTypes: planned.previousTypes, migrations: planned.migrations};
		}
		var changed:Array<Int> = [], changedSlots:Array<Int> = [];
		if (initialized)
			for (name in regenerated) {
				if (layout.exists(name) && cache.stableIds.exists(name)) {
					var index = layout.get(name),
						stableId = cache.stableIds.get(name);
					changedSlots.push(index);
					changed.push(stableId);
				}
			}
		changed.sort(function(a, b) return a - b);
		changedSlots.sort(function(a, b) return a - b);
		var addedFunctions:Array<{slot:Int, name:String}> = [];
		if (initialized && !reload)
			for (index in publishedSlots...cache.slots.length) {
				var name = cache.slots[index], slot = layout.get(name);
				if (slot == null)
					throw 'Added function $name has no slot';
				addedFunctions.push({slot: slot, name: name});
			}
		var lowered = HlLower.lowerStableMeasured(ordered, symbols, layout, cache.stableIds, reuseLowered ? loweredFunctions : null,
			relocated == null ? regenerated : regenerated.concat(relocated), runtimeNatives, debugMetadata, fieldReserve),
			module = lowered.code;
		var loweredAt = Sys.time() * 1000.0;
		// A running module can take new String constants and the value slots of new object types but no other global, so a
		// build that adds any other publishes a fresh module. The ABI plan already asks for that when a static field is added; this guards the rest.
		if (initialized && !reload && !addsOnlyPatchableGlobals(module)) {
			reload = true;
			layoutReasons.push('globals $publishedGlobals -> ${module.globals.length} add more than String constants and new types');
		}
		loweredFunctions = [];
		for (index in 0...ordered.functions.length)
			loweredFunctions.set(ordered.functions[index].name, module.functions[index]);
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
		var unchanged = initialized && !reload && changed.length == 0 && addedFunctions.length == 0 && objectLayout == null && baseInts == publishedInts
			&& baseFloats == publishedFloats && baseStrings == publishedStrings && baseTypes == publishedTypes && baseGlobals == publishedGlobals;
		if (!unchanged)
			revision = lastRevision() + 1;
		initialized = true;
		return {
			module: module,
			changedFunctions: changed,
			changedSlots: changedSlots,
			addedFunctions: addedFunctions,
			functionIndices: layout,
			requiresReload: reload,
			baseRevision: baseRevision,
			layoutReasons: layoutReasons,
			objectReasons: objectReasons,
			objectLayout: reload ? null : objectLayout,
			revision: revision,
			baseInts: baseInts,
			baseFloats: baseFloats,
			baseStrings: baseStrings,
			baseTypes: baseTypes,
			baseGlobals: baseGlobals,
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
