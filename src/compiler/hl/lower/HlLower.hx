package compiler.hl.lower;

import compiler.core.InternalError;
import compiler.hl.incremental.HlSymbolRequest.HlRuntimeHeader;
import compiler.ir.IrTypeIdentity;
import compiler.ir.IrFunction;
import compiler.ir.PhiEdges;
import compiler.hl.HlCode;
import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.HlFunction;
import compiler.hl.HlFunction.HlInstruction;
import compiler.hl.HlFunction.HlDebugLocation;
import compiler.hl.HlCode.HlDebugSection;
import compiler.hl.HlFunction.HlDebugAssignment;
import compiler.hl.HlType;
import compiler.hl.HlWriter;
import compiler.hl.incremental.HlSymbolTable;
import compiler.ir.Ir.IrInstruction;
import compiler.ir.Ir.IrTerminator;
import compiler.ir.Ir.IrBlock;
import compiler.ir.Ir.IrNative;
import compiler.ir.Ir.IrCNative;
import compiler.ir.Ir.IrObject;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.ir.Ir.IrValue;
import compiler.ir.IrVerifier;
import compiler.hl.lower.HlScalarValueLocals.HlScalarValueLocal;
import compiler.hl.incremental.HlSymbolRequest;
import compiler.hl.incremental.HlSymbolRequest.HlRemap;
import compiler.ir.SourceProvenance;
import compiler.core.AllocationMeter;
import compiler.core.AllocationMeter.PhaseAllocation;

typedef HlLowerMetrics = {
	final allocationPhases:Array<PhaseAllocation>;
	final verificationMs:Float;
	final metadataMs:Float;
	final functionsMs:Float;
	final debugMs:Float;
	final finalizationMs:Float;
}

typedef MeasuredHlCode = {
	/** Each function lowered by this call with the requests and facts its code depends on, when asked to record them. */
	final lowered:Map<String, compiler.hl.incremental.HlLoweredFunction>;

	/** How many functions were linked from the cache instead of lowered. */
	final reusedFunctions:Int;

	/** How many of them got other indices than they were lowered with. */
	final movedFunctions:Int;

	final code:HlCode;
	final metrics:HlLowerMetrics;
}

/** Lowers verified SSA IR into indexed HashLink types, registers, and opcodes. */
class HlLower {
	final code:HlCode;
	final symbols:HlSymbolTable;
	final functionIndices:Map<String, Int> = [];
	final objectTypeIndices:Map<String, Int> = [];

	/** Everything lowering a function may learn about an object type; see `HlLoweringView`. */
	var view:HlLoweringView;

	/** The requests the function being lowered makes, when lowering records them. */
	var requests:Null<Array<HlSymbolRequest>>;

	/** Whether lowering keeps, for each function, the requests and facts that let a later build reuse its code. */
	final recordLowering:Bool;

	/** The next label `freshLabel` gives, past the function's last block id. */
	var nextLabel = 0;

	// Tables by value id of the function being lowered, their storage kept from one function to the next.
	final valueRegisters:Array<Int> = [];

	/**
	 * A function's instructions and their debug locations are built here and copied out at their final length, so a
	 * function's arrays are allocated once rather than regrown as it is lowered.
	 */
	final instructionScratch:Array<HlInstruction> = [];

	final locationScratch:Array<HlDebugLocation> = [];

	/** The tables of the non-null analysis, reused across functions. */
	final nonNullScratch = new compiler.ir.IrPassScratch.IrNonNullScratch();
	final valueIsNull:Array<Bool> = [];
	final valueUses:Array<Int> = [];

	/** Register allocation of release code, its scratch reused from one function to the next. */
	final registerAllocation = new HlRegisterAllocation();

	/** The functions of the last build, to link instead of lowering again; filled with this build's at the end. */
	final loweredCache:Null<compiler.hl.incremental.HlLoweredCache>;

	/** How many functions this build took from the cache. */
	public var reusedFunctions = 0;

	/** How many of those got other indices than they were lowered with. */
	public var movedFunctions = 0;

	final checkingLinks:Bool;

	/** `--check-reuse` on a build that trusts its cache: every kept function is lowered again and compared. */
	final checkingTrust:Bool;

	/** Kept functions whose code is frozen on purpose (retired by a signature change, or dropped from the program): check mode leaves them be. */
	final frozen:Null<String->Bool>;

	/** Kept functions check mode could not lower again, with the missing object or field. */
	final skippedKept:Array<String> = [];

	/** Kept functions check mode skipped in this process, and whether it said so yet: a check-mode report, given once a process. */
	@:processWide("a check-mode diagnostic, reported once per process; never part of a module")
	public static var skippedKeptTotal = 0;

	@:processWide("a check-mode diagnostic, reported once per process; never part of a module")
	static var reportedSkips = false;

	/** Each lowered function with what it leans on, by name (see `HlLoweredFunction`). */
	public final lowered:Map<String, compiler.hl.incremental.HlLoweredFunction> = [];

	/** The owner `Class.field` was found on, by `Class.field`, for the field slot request. */
	final interfaceBases:Map<String, Array<String>> = [];

	final enumTypeIndices:Map<String, Int> = [];
	final cNatives:Map<String, IrCNative> = [];
	final cDispatchNatives:Array<IrNative> = [];
	final preparedRuntimeNatives:Null<Array<IrNative>>;

	public static function lower(program:IrProgram, ?indices:Map<String, Int>):HlCode {
		IrVerifier.verify(program);
		var lowerer = new HlLower(new HlSymbolTable(), null),
			code = lowerer.lowerProgram(program);
		if (indices != null)
			for (name => index in lowerer.functionIndices)
				indices.set(name, index);
		return code;
	}

	public static function lowerStableMeasured(program:IrProgram, symbols:HlSymbolTable, indices:Map<String, Int>,
			?stableIds:Map<String, Int>,
			?regenerated:Array<String>, ?runtimeNatives:Array<IrNative>, ?debugCache:HlDebugMetadataCache,
			fieldReserve:Int = 0,
			developmentMetadata:Bool = true, recordLowering:Bool = false,
			?loweredCache:compiler.hl.incremental.HlLoweredCache, irVerified:Bool = false,
			trustCache:Bool = false, ?frozen:String->Bool, checkReuse:Bool = false):MeasuredHlCode {
		var startedAt = Sys.time() * 1000.0;
		var allocationAtStart = AllocationMeter.sample();
		var affected = regenerated;
		if (!trustCache || regenerated == null || loweredCache == null || !loweredCache.entries.iterator().hasNext()) {
			// The final IR of a plain build is verified where it is made (`FrontendCompilation`), once, whatever the backend.
			// A frozen function (a retired signature, or a lambda the program dropped) is code the running module holds for
			// its closures: the objects it names may be gone from the program, so it is lowered against the published types
			// and not verified against this program.
			if (!irVerified && frozen != null) {
				var selected:Map<String, Bool> = [];
				for (fn in program.functions)
					if (!frozen(fn.name))
						selected.set(fn.name, true);
				IrVerifier.verifyFunctions(program, selected);
			} else if (!irVerified)
				IrVerifier.verify(program);
		} else {
			// Only regenerated functions are lowered again. Every other function's IR compared equal, provenance and file
			// hash included, so its cached lowering is still exact; re-lowering every function that touched a changed file
			// redid most of the program on each edit and produced the same bytes.
			var selected:Map<String, Bool> = [];
			for (name in regenerated)
				selected.set(name, true);
			IrVerifier.verifyFunctions(program, selected);
		}
		var verifiedAt = Sys.time() * 1000.0,
			allocationAfterVerification = AllocationMeter.sample(),
			lowerer = new HlLower(symbols, indices, stableIds, affected, runtimeNatives, debugCache, fieldReserve,
				developmentMetadata, recordLowering,
				loweredCache, trustCache, frozen, checkReuse),
			code = lowerer.lowerProgram(program);
		return {
			code: code,
			lowered: lowerer.lowered,
			reusedFunctions: lowerer.reusedFunctions,
			movedFunctions: lowerer.movedFunctions,
			metrics: {
				allocationPhases: [
					AllocationMeter.delta("backend-verification", allocationAtStart, allocationAfterVerification)
				].concat(lowerer.allocationPhases),
				verificationMs: verifiedAt - startedAt,
				metadataMs: lowerer.metadataMs,
				functionsMs: lowerer.functionsMs,
				debugMs: lowerer.debugMs,
				finalizationMs: lowerer.finalizationMs
			}
		};
	}

	final stableIds:Null<Map<String, Int>>;

	/** The cache is the caller's word: every entry not named in `regenerated` is kept as it is (live patching), with no IR comparison, and the entries made carry no requests. */
	final trustCache:Bool;

	/** Reserved slots a live build gives each object that can take fields later (see `reservedSlots`). */
	final fieldReserve:Int;

	/** HashLink field indices by `object.field`, resolved against the types this build publishes. */
	/** The slot of an object field and the object that declares it, by type name then field name: a lookup makes no key string. */
	final fieldSlots:Map<String, Map<String, {index:Int, owner:String}>> = [];

	/** Objects a native signature reaches, which keep the layout the natives were built against (see `reservedSlots`). */
	var nativeVisible:Map<String, Bool> = [];

	final regenerated:Map<String, Bool> = [];
	final debugCache:Null<HlDebugMetadataCache>;
	final developmentMetadata:Bool;

	var typedInterfaces:HlTypedInterfaceTables;
	var metadataMs = 0.0;
	var functionsMs = 0.0;
	var debugMs = 0.0;
	var finalizationMs = 0.0;
	var allocationPhases:Array<PhaseAllocation> = [];

	function new(symbols:HlSymbolTable, indices:Null<Map<String, Int>>, ?stableIds:Map<String, Int>,
			?regenerated:Array<String>,
			?runtimeNatives:Array<IrNative>, ?debugCache:HlDebugMetadataCache, fieldReserve:Int = 0,
			developmentMetadata:Bool = true,
			recordLowering:Bool = false, ?loweredCache:compiler.hl.incremental.HlLoweredCache, trustCache:Bool = false,
			?frozen:String->Bool, checkReuse:Bool = false) {
		this.frozen = frozen;
		this.symbols = symbols;
		// A compile that checks its reuse lowers with requests recorded so the link step can be checked against this very lowering.
		this.checkingLinks = !trustCache && checkReuse;
		this.loweredCache = loweredCache;
		this.checkingTrust = trustCache && checkReuse;
		this.recordLowering = !trustCache && (recordLowering || checkingLinks || loweredCache != null);
		this.fieldReserve = fieldReserve;
		this.stableIds = stableIds;
		this.trustCache = trustCache;
		this.preparedRuntimeNatives = runtimeNatives;
		this.debugCache = debugCache;
		this.developmentMetadata = developmentMetadata;
		if (regenerated != null)
			for (name in regenerated)
				this.regenerated.set(name, true);
		code = new HlCode();
		code.ints = symbols.ints;
		code.floats = symbols.floats;
		code.strings = symbols.strings;
		code.types = symbols.types;
		code.globals = symbols.globals;
		if (indices != null)
			for (name => index in indices)
				functionIndices.set(name, index);
	}

	function lowerProgram(program:IrProgram):HlCode {
		typedInterfaces = new HlTypedInterfaceTables(program);
		view = new HlLoweringView(typedInterfaces.keys);
		var runtimeNatives = preparedRuntimeNatives == null
			? discoverRuntimeNatives(program) : preparedRuntimeNatives.copy();
		for (native in program.cNatives) {
			cNatives.set(native.name, native);
			var arity = native.arguments.length;
			if (arity > 16)
				throw new InternalError('Ordinary C calls support at most 16 arguments, got $arity for "${native.name}"');
			if ((isNativePointer(native.result) || isManagedPointerBytes(native) || isUtf8Result(native))
				&& native.pointerOwnership == "unspecified")
				throw new InternalError('Ordinary C pointer result "${native.name}" requires @borrowed or @owned metadata before execution');
		}
		for (native in discoverCDispatchNatives(program))
			cDispatchNatives.push(native);
		lowerProgramWithNatives(program, runtimeNatives);
		return code;
	}

	/**
	 * The runtime natives that ordinary C calls dispatch through, one per call shape, in first-use order. A module's layout
	 * places them with the other natives, before every function, so functions a later build appends never move them.
	 */
	public static function discoverCDispatchNatives(program:IrProgram):Array<IrNative> {
		var result:Array<IrNative> = [],
			dispatchArities:Map<String, Bool> = [];
		for (native in program.cNatives) {
			var arity = native.arguments.length;
			var pointerResult = isNativePointer(native.result),
				bytesResult = isManagedPointerBytes(native),
				aggregateResult = isAggregateResult(native),
				utf8Result = isUtf8Result(native),
				dispatchKey = '$arity:$pointerResult:$bytesResult:$aggregateResult:$utf8Result';
			if (!dispatchArities.exists(dispatchKey)) {
				dispatchArities.set(dispatchKey, true);
				result.push({
					name: pointerResult ? '__c_native_pointer_invoke_$arity' : bytesResult
						? '__c_native_bytes_invoke_$arity' : aggregateResult ? '__c_native_aggregate_invoke_$arity'
						: utf8Result ? '__c_native_utf8_invoke_$arity' : '__c_native_invoke_$arity',
					library: "haxeon_runtime",
					symbol: pointerResult ? 'native_pointer_invoke_$arity' : bytesResult
						? 'native_bytes_invoke_$arity' : aggregateResult ? 'native_aggregate_invoke_$arity' : utf8Result
						? 'native_utf8_invoke_$arity' : 'native_invoke_$arity',
					arguments: ((pointerResult || utf8Result) ? [
						IrType.RawPtr,
						IrType.RawPtr,
						IrType.RawPtr,
						IrType.RawPtr,
						IrType.RawPtr,
						IrType.Bool
					] : bytesResult ? [
						IrType.RawPtr,
						IrType.RawPtr,
						IrType.RawPtr,
						IrType.RawPtr,
						IrType.RawPtr,
						IrType.RawPtr,
						IrType.Bool
					] : [
						IrType.RawPtr,
						IrType.RawPtr,
						IrType.RawPtr
					]).concat([for (_ in 0...arity) IrType.Dyn]),
					result: pointerResult ? IrType.Abstract("native_pointer") : (bytesResult || aggregateResult)
						? IrType.Abstract("realtime_bytes") : utf8Result ? IrType.Bytes : IrType.Dyn
				});
			}
		}
		return result;
	}

	public static function discoverRuntimeNatives(program:IrProgram, ?baseline:Array<IrNative>,
			?selected:Array<String>):Array<IrNative> {
		var runtimeNatives = baseline == null ? program.natives.copy() : baseline.copy(),
			selectedNames:Map<String, Bool> = [];
		if (baseline != null)
			for (native in program.natives)
				ensureNative(runtimeNatives, native.name, native.arguments, native.result, native.library,
					native.symbol);
		if (Lambda.exists(program.functions, fn -> compiler.ir.IrTypedInterfaceDispatch.isDispatchEntry(fn.name))) {
			ensureNative(runtimeNatives, HlTypedInterfaceTables.SLOT_NATIVE, [IrType.TypeRef],
				IrType.Abstract(HlTypedInterfaceTables.SLOT_TYPE), "std",
				"typed_method_slot");
			ensureNative(runtimeNatives, HlTypedInterfaceTables.ENTRY_NATIVE, [
				IrType.Dyn,
				IrType.Abstract(HlTypedInterfaceTables.SLOT_TYPE)
			],
				IrType.Abstract(HlTypedInterfaceTables.ENTRY_TYPE), "std", "typed_method_entry");
		}
		if (selected != null)
			for (name in selected)
				selectedNames.set(name, true);
		for (fn in program.functions)
			if (selected == null || selectedNames.exists(fn.name))
				for (block in fn.blocks)
					for (located in block.instructions)
						switch located.value {
							case CallClosure(_, closure, _) if ((switch (closure.type) {
								case IrType.Dyn: true;
								default: false;
							})): ensureNative(runtimeNatives, "__reflect_is_function", [IrType.Dyn], IrType.Bool);
							ensureNative(runtimeNatives, "__string_from_bytes", [IrType.RawPtr, IrType.I32],
								IrType.Bytes);
							case PointerOffset(_, _, _):
								ensureNative(runtimeNatives, "__hl_bytes_offset", [IrType.RawPtr, IrType.I32],
									IrType.RawPtr, "std", "bytes_offset");
							case IteratorNew(_, _):
								ensureNative(runtimeNatives, "__iterator_new", [IrType.Dyn],
									IrType.Abstract("realtime_iterator"));
							case IteratorHasNext(_, _):
								ensureNative(runtimeNatives, "__iterator_has_next",
									[IrType.Abstract("realtime_iterator")], IrType.Bool);
							case Call(_, name, arguments) if (name.name == VALUE_ARRAY_READ_I32 && arguments.length == 5
								&& readsInline(arguments[0].type)):
								ensureNative(runtimeNatives, VALUE_ARRAY_HEADER_TYPE, [], IrType.TypeRef);
								ensureNative(runtimeNatives, VALUE_ARRAY_FORWARD_TYPE, [], IrType.TypeRef);
							case ArrayGet(_, array, _):
								ensureRawArrayNative(runtimeNatives, array.type, "check");
							case ArraySet(array, _, _):
								ensureRawArrayNative(runtimeNatives, array.type, "ensure");
							case IteratorNext(output, _):
								var nextNative = iteratorNextNative(output.type);
								ensureNative(runtimeNatives, nextNative.name, [IrType.Abstract("realtime_iterator")],
									nextNative.result);
							default:
						}
		return runtimeNatives;
	}

	function lowerProgramWithNatives(program:IrProgram, runtimeNatives:Array<IrNative>):Void {
		var startedAt = Sys.time() * 1000.0;
		var allocationAtStart = AllocationMeter.sample();
		var hasFunctionIndices = false;
		for (_ in functionIndices)
			hasFunctionIndices = true;
		if (!hasFunctionIndices) {
			var nextFunction = 0;
			for (native in runtimeNatives)
				addFunctionName(native.name, nextFunction++);
			for (native in cDispatchNatives)
				addFunctionName(native.name, nextFunction++);
			for (fn in program.functions)
				addFunctionName(fn.name, nextFunction++);
		} else {
			var nextFunction = 0;
			for (index in functionIndices)
				if (index >= nextFunction)
					nextFunction = index + 1;
			for (native in runtimeNatives)
				if (!functionIndices.exists(native.name))
					addFunctionName(native.name, nextFunction++);
			for (native in cDispatchNatives)
				if (!functionIndices.exists(native.name))
					addFunctionName(native.name, nextFunction++);
		}
		// Patches cannot add object types, so every base module carries String.
		internType(IrType.Bytes);
		var runtimeEnums = developmentMetadata ? program.enums : compiler.ir.IrEnumRuntimeTypes.declarations(program);
		var boxedEnums = [for (declaration in runtimeEnums) declaration.name => true];
		for (declaration in program.enums)
			if (!boxedEnums.exists(declaration.name))
				symbols.internScalarEnumTag(declaration.name);
		for (enumDecl in runtimeEnums)
			symbols.reserveEnum(enumDecl);
		for (interfaceDecl in program.interfaces) {
			symbols.reserveInterface(interfaceDecl.name);
			interfaceBases.set(interfaceDecl.name, interfaceDecl.bases);
		}
		for (object in program.objects)
			symbols.reserveObject(object.name);
		if (fieldReserve > 0)
			nativeVisible = nativeVisibleObjects(program.objects, [runtimeNatives, cDispatchNatives]);
		var valueObjects:Map<String, Bool> = [];
		for (object in program.objects)
			if (object.isValue)
				valueObjects.set(object.name, true);
		for (enumDecl in runtimeEnums)
			enumTypeIndices.set(enumDecl.name, symbols.internEnum(enumDecl));
		var pendingInterfaces = program.interfaces.copy();
		while (pendingInterfaces.length > 0) {
			var progressed = false;
			var remainingInterfaces:Array<compiler.ir.Ir.IrInterface> = [];
			for (interfaceDecl in pendingInterfaces) {
				var ready = true;
				for (base in interfaceDecl.bases)
					if (!symbols.hasInterfaceMethods(base))
						ready = false;
				if (ready) {
					symbols.internInterface(interfaceDecl);
					progressed = true;
				} else
					remainingInterfaces.push(interfaceDecl);
			}
			if (!progressed)
				throw new InternalError('Unable to order interface bases');
			pendingInterfaces = remainingInterfaces;
		}
		var pending = program.objects.copy();
		while (pending.length > 0) {
			var progressed = false;
			var remaining:Array<IrObject> = [];
			for (object in pending) {
				var ready = true;
				if (object.base != null) {
					var baseName = Std.string(object.base);
					ready = objectTypeIndices.exists(baseName) || symbols.hasObjectMethods(baseName);
				}
				var fieldsReady = true;
				for (field in object.fields)
					if (!objectTypeReady(field.type))
						fieldsReady = false;
				if (ready && fieldsReady) {
					view.define(object);
					var slots = interfaceSlotsFor(object);
					objectTypeIndices.set(object.name,
						symbols.internObject(object, functionIndices, valueObjects, slots, reservedSlots(object),
						typedInterfaces.entries.get(object.name)));
					progressed = true;
				} else
					remaining.push(object);
			}
			if (!progressed)
				throw new InternalError('Unable to order object metadata dependencies');
			pending = remaining;
		}
		for (field in program.staticFields)
			symbols.internGlobal(field.name, field.type);
		for (native in runtimeNatives)
			lowerNative(native);
		for (native in cDispatchNatives)
			lowerNative(native);
		var metadataDoneAt = Sys.time() * 1000.0;
		var allocationAfterMetadata = AllocationMeter.sample();
		var environment = checkingLinks ? symbols.copy() : null;
		var entries:Map<String, compiler.hl.incremental.HlLoweredFunction> = [];
		for (fn in program.functions) {
			var kept = trustCache && !regenerated.exists(fn.name)
				&& loweredCache != null ? loweredCache.entries.get(fn.name) : null;
			if (kept != null) {
				// A frozen function is the code of an earlier signature, or of a lambda the program dropped, kept for closures that still call it; its stale IR lowered against this build is not what it holds.
				if (checkingTrust && (frozen == null || !frozen(fn.name)))
					verifyKept(fn, kept.fn);
				code.functions.push(kept.fn);
				entries.set(fn.name, kept);
			} else {
				// A function whose IR is the one the last build lowered, and whose outside facts still hold, keeps its code: linking
				// it replays its requests, which gives it this build's indices and makes the tables as lowering it would have.
				var entry = loweredCache == null || trustCache ? null : loweredCache.entries.get(fn.name);
				if (entry != null
					&& (entry.source == fn || compiler.ir.codec.IrFunctionStateEquality.same(entry.source, fn))) {
					var linked = compiler.hl.incremental.HlLink.link(entry, symbols, functionIndices, view);
					if (linked.fn != null) {
						code.functions.push(linked.fn);
						entries.set(fn.name, entry.source == fn ? entry : entry.from(fn));
						this.lowered.set(fn.name, entry);
						reusedFunctions++;
						if (linked.fn != entry.fn)
							movedFunctions++;
						continue;
					}
				}
				try {
					if (recordLowering) {
						requests = [];
						view.beginFunction();
					}
					var lowered = lowerFunction(PhiEdges.split(fn));
					code.functions.push(lowered);
					if (trustCache) {
						entries.set(fn.name,
							new compiler.hl.incremental.HlLoweredFunction(fn.name, fn, lowered, [], []));
						requests = null;
					} else if (recordLowering) {
						var entry = new compiler.hl.incremental.HlLoweredFunction(fn.name, fn, lowered, requests,
							view.endFunction());
						this.lowered.set(fn.name, entry);
						entries.set(fn.name, entry);
						requests = null;
					}
				} catch (error:InternalError) {
					throw new InternalError('HashLink lowering failed for ${fn.name}: ${error.message}', error.span);
				} catch (missing:HlMissingEntity) {
					throw new InternalError('HashLink lowering failed for ${fn.name}: ${missing.message}');
				}
			}
		}
		if (loweredCache != null)
			loweredCache.entries = entries;
		if (skippedKept.length > 0) {
			// Once per process, a few names: a test driver reads a child's stderr after it exits, and a line per build fills the pipe.
			skippedKeptTotal += skippedKept.length;
			if (!reportedSkips) {
				reportedSkips = true;
				Sys.stderr()
					.writeString('--check-reuse: kept functions could not be lowered again because their objects or fields are gone, e.g. ${skippedKept.slice(0, 3).join(", ")}\n');
			}
		}
		if (environment != null && reusedFunctions == 0)
			verifyLinking(program, environment);
		var functionsDoneAt = Sys.time() * 1000.0;
		var allocationAfterFunctions = AllocationMeter.sample();
		// The VM uses function identities for stack-trace and profiler names in every mode.
		var identities = [for (fn in program.functions) cachedFunctionIdentity(fn)];
		code.debugSections.push(HlDebugSection.of(HlWriter.FUNCTION_IDENTITIES, 1, 0,
			HlWriter.encodeFunctionIdentities(identities)));
		var allocationAfterIdentities = AllocationMeter.sample(),
			allocationAfterSpanGroups = allocationAfterIdentities;
		if (developmentMetadata) {
			var spanGroups:Array<compiler.hl.HlWriter.HlOpcodeSourceSpanGroup> = [];
			for (index in 0...code.functions.length) {
				var identity = identities[index],
					loweredFunction = code.functions[index];
				spanGroups.push({
					stableId: identity.stableId,
					locations: loweredFunction.debugLocations,
					opcodes: loweredFunction.opcodes
				});
			}
			allocationAfterSpanGroups = AllocationMeter.sample();
			// The groups only point at the functions' locations; the section is encoded when the module is written.
			code.debugSections.push(HlDebugSection.lazy(HlWriter.OPCODE_SOURCE_SPANS, 2, 0,
				cache -> HlWriter.encodeOpcodeSourceSpanGroups(spanGroups, cache)));
		}
		if (debugCache != null)
			debugCache.endGeneration();
		var debugDoneAt = Sys.time() * 1000.0;
		var allocationAfterDebug = AllocationMeter.sample();

		code.entryPoint = requireFunction(program.entryPoint);
		for (literal in symbols.stringConstantGlobals())
			code.constants.push({
				global: literal.global,
				// The String's fields: its data, its length and its hash, which a string map computes and keeps on first use.
				fields: [
					symbols.internString(literal.value),
					symbols.internInt(HlSymbolTable.utf16Length(literal.value)),
					symbols.internInt(0)
				]
			});
		code.ints = symbols.ints;
		code.floats = symbols.floats;
		code.strings = symbols.strings;
		code.types = symbols.types;
		code.globals = symbols.globals;
		var finalizedAt = Sys.time() * 1000.0;
		var allocationAfterFinalize = AllocationMeter.sample();
		allocationPhases = [
			AllocationMeter.delta("backend-metadata", allocationAtStart, allocationAfterMetadata),
			AllocationMeter.delta("backend-functions", allocationAfterMetadata, allocationAfterFunctions),
			AllocationMeter.delta("backend-debug", allocationAfterFunctions, allocationAfterDebug),
			AllocationMeter.delta("backend-debug-identities", allocationAfterFunctions, allocationAfterIdentities),
			AllocationMeter.delta("backend-debug-span-groups", allocationAfterIdentities, allocationAfterSpanGroups),
			AllocationMeter.delta("backend-debug-encode", allocationAfterSpanGroups, allocationAfterDebug),
			AllocationMeter.delta("backend-finalize", allocationAfterDebug, allocationAfterFinalize)
		];
		metadataMs = metadataDoneAt - startedAt;
		functionsMs = functionsDoneAt - metadataDoneAt;
		debugMs = debugDoneAt - functionsDoneAt;
		finalizationMs = finalizedAt - debugDoneAt;
	}

	/**
	 * Checks the link step against the lowering that just ran: the requests of every function, replayed in order against the tables as
	 * they stood before the functions, must give back the very tables lowering made, and every function must keep its indices.
	 */
	function verifyLinking(program:IrProgram, environment:HlSymbolTable):Void {
		for (fn in program.functions) {
			var lowered = this.lowered.get(fn.name);
			if (lowered == null)
				throw new InternalError('--check-reuse: no lowering was recorded for ${fn.name}');
			var linked = compiler.hl.incremental.HlLink.link(lowered, environment, functionIndices, view);
			if (linked.fn == null)
				throw new InternalError('--check-reuse: linking ${fn.name} against the tables it was lowered with failed: ${linked.reason}');
			if (linked.fn != lowered.fn)
				throw new InternalError('--check-reuse: linking ${fn.name} against the tables it was lowered with moved its indices');
		}

		sameReplayTable("the integer", symbols.ints, environment.ints);
		sameReplayTable("the float", symbols.floats, environment.floats);
		sameReplayTable("the string", symbols.strings, environment.strings);
		sameReplayTable("the global", symbols.globals, environment.globals);
		sameReplayTable("the type", symbols.types, environment.types);
	}

	static function sameReplayTable<T>(what:String, expected:Array<T>, actual:Array<T>):Void {
		if (expected.length != actual.length)
			throw new InternalError('--check-reuse: replaying the requests made $what table of ${actual.length} entries, lowering made ${expected.length}');
		for (index in 0...expected.length)
			if (Std.string(expected[index]) != Std.string(actual[index]))
				throw new InternalError('--check-reuse: replaying the requests made $what ${index} different from lowering\'s: ${Std.string(actual[index])} and ${Std.string(expected[index])}');
	}

	/**
	 * A live build keeps a function because the caller says nothing it leans on changed. Lowering it again must give the same code
	 * and add nothing to the tables; if not, the set of regenerated functions was wrong.
	 */
	function verifyKept(fn:IrFunction, kept:HlFunction):Void {
		function sizes():String
			return [
				symbols.ints.length,
				symbols.floats.length,
				symbols.strings.length,
				symbols.types.length,
				symbols.globals.length
			].join(",");
		var before = sizes();
		var fresh:HlFunction;
		try
			fresh = lowerFunction(PhiEdges.split(fn))
		catch (missing:HlMissingEntity) {
			// Only an object type or field the program no longer holds excuses it: a removed lambda whose code stored closures still run
			// keeps its old code on purpose, and there is nothing to compare it with. Lowering must have added nothing before it failed.
			if (sizes() != before)
				throw new InternalError('--check-reuse: lowering kept function ${fn.name} added symbols (ints, floats, strings, types, globals $before -> ${sizes()}) before failing: $missing');
			skippedKept.push('${fn.name} ($missing)');
			return;
		}
		if (sizes() != before)
			throw new InternalError('--check-reuse: kept function ${fn.name} added symbols when lowered again (ints, floats, strings, types, globals $before -> ${sizes()})');
		var difference = compiler.hl.HlFunctionEquality.difference(kept, fresh);
		if (difference != null)
			throw new InternalError('--check-reuse: kept function ${fn.name} lowers to other code than its cached lowering: $difference');
	}

	function cachedFunctionIdentity(fn:IrFunction):compiler.hl.HlCode.HlFunctionIdentity {
		var cached = debugCache == null ? null : debugCache.identity(fn);
		if (cached != null && cached.functionIndex == requireFunction(fn.name))
			return cached;
		var identity = functionIdentity(fn);
		if (debugCache != null)
			debugCache.rememberIdentity(fn, identity);
		return identity;
	}

	function functionIdentity(fn:IrFunction):compiler.hl.HlCode.HlFunctionIdentity {
		var functionIndex = requireFunction(fn.name), sourcePath = "", start = -1, end = -1, line = 0;
		for (block in fn.blocks)
			for (instruction in block.instructions) {
				var location = instruction.provenance.location;
				if (location == null)
					continue;
				if (sourcePath == "")
					sourcePath = location.path;
				if (start < 0 || location.start < start)
					start = location.start;
				if (end < location.end)
					end = location.end;
				if (line == 0 || location.line < line)
					line = location.line;
			}
		var parts = fn.name.split(".");
		return {
			stableId: stableIds != null && stableIds.exists(fn.name) ? stableIds.get(fn.name) : functionIndex,
			functionIndex: functionIndex,
			qualifiedName: fn.name,
			displayName: parts[parts.length - 1],
			sourcePath: sourcePath,
			start: start,
			end: end,
			line: line,
			flags: StringTools.startsWith(fn.name, "__") ? 1 : 0
		};
	}

	function objectTypeReady(type:IrType):Bool
		return switch type {
			case Obj(name): objectTypeIndices.exists(name) || symbols.hasType('obj:$name');
			case Function(arguments, result):
				var ready = objectTypeReady(result);
				for (argument in arguments)
					if (!objectTypeReady(argument))
						ready = false;
				ready;
			default: true;
		};

	/** Byte shift of one element of an Int or Float array, whose storage the compiler lays out itself; null for any other array. */
	static inline final VALUE_ARRAY_VALIDATE = "__value_array_validate";

	static inline final VALUE_ARRAY_READ_I32 = "__value_array_read_i32";

	/** The runtime's type of a value array header, which a forwarding header does not have (`value_arrays.c`). */
	static inline final VALUE_ARRAY_HEADER_TYPE = "__value_array_header_type";

	static inline final VALUE_ARRAY_FORWARD_TYPE = "__value_array_forward_type";

	/** Where a value array keeps its scalar stride in bits, and an array its size and data; `value_arrays.c` asserts them. */
	static inline final VALUE_ARRAY_STRIDE_OFFSET = 88;

	static inline final ARRAY_SIZE_OFFSET = 16;

	/** Where a value array keeps its validity lane (`value_arrays.c` asserts it). */
	static inline final VALUE_ARRAY_VALIDITY_OFFSET = 104;
	static inline final ARRAY_DATA_OFFSET = 24;

	/** The type word at the start of an array's storage. */
	static inline final LANE_HEADER_BYTES = 8;

	/** How far back from a call its constant arguments are looked for; the IR emits them right before it. */
	static inline final CONSTANT_LOOKBACK = 8;

	/** The Int or Bool constant (a Bool as 0 or 1) `value` is, when its definition is just before `index`; else -1. */
	static function constantBefore(instructions:Array<compiler.ir.SourceProvenance.Located<IrInstruction>>, index:Int,
			value:IrValue):Int {
		var position = index - 1, limit = index - CONSTANT_LOOKBACK;
		while (position >= 0 && position >= limit) {
			switch instructions[position].value {
				case ConstInt(output, number) if (output.id == value.id):
					return number;
				case ConstBool(output, flag) if (output.id == value.id):
					return flag ? 1 : 0;
				default:
			}
			position--;
		}
		return -1;
	}

	/** Whether a value array of `array`'s type is read inline (`hasValidity` tells how). */
	static function readsInline(array:IrType):Bool
		return switch array {
			case Array(EnumTag(_)), Array(Enum(_)), Array(Nullable(Obj(_))), Array(Obj(_)): true;
			default: false;
		};

	/**
	 * Whether a value array of `array`'s type keeps a presence bit per element (`IrValueArrayLayout`): arrays of non-null
	 * structs do; enums (their null is tag zero) and nullable structs do not.
	 */
	static function hasValidity(array:IrType):Bool
		return switch array {
			case Array(Obj(_)): true;
			default: false;
		};

	/**
	 * The slot `__value_array_read_i32` at `index` of `instructions` reads, as constants, when it is read inline
	 * (`lowerValueArrayRead`); null otherwise.
	 */
	static function inlineValueArraySlot(instructions:Array<compiler.ir.SourceProvenance.Located<IrInstruction>>,
			index:Int,
			arguments:Array<IrValue>):Null<InlineValueSlot> {
		if (arguments.length != 5 || !readsInline(arguments[0].type))
			return null;
		var offset = constantBefore(instructions, index, arguments[2]),
			width = constantBefore(instructions, index, arguments[3]),
			signed = constantBefore(instructions, index, arguments[4]);
		return offset >= 0 && offset % 8 == 0 && signed >= 0 && (width == 8 || width == 16 || width == 32)
			? {offset: offset, width: width, signed: signed == 1} : null;
	}

	/**
	 * A scalar read of a value array element, inline (`VALUE_ARRAY_ACCESS.md`): with the array's header resolved to its
	 * value array (`valueArrayView`), an index in range, of an element present (for arrays with validity bits), loads the
	 * slot from the scalar lane, `index * stride + offset`; anything else calls the native, which raises its errors as
	 * before.
	 */
	function lowerValueArrayRead(output:IrValue, arguments:Array<IrValue>, slot:InlineValueSlot, block:Int,
			instructions:Array<HlInstruction>, registers:Array<Int>, registerTypes:Array<Int>):Void {
		var array = requireRegister(arguments[0], registers),
			index = requireRegister(arguments[1], registers),
			destination = defineRegister(output, registers, registerTypes),
			view = valueArrayView(arguments[0], instructions, registers, registerTypes),
			slow = freshLabel(),
			done = freshLabel(),
			size = temporaryRegister(IrType.I32, registerTypes),
			data = temporaryRegister(IrType.Bytes, registerTypes),
			position = temporaryRegister(IrType.I32, registerTypes);
		instructions.push(HlInstruction.JumpNull(view.array, slow));
		// A loop that runs the index up to the array's length, and resizes nothing, proved it in range.
		if (!provenByLoop(arguments[0], arguments[1], block)) {
			instructions.push(HlInstruction.GetMem(size, view.array,
				constantRegister(ARRAY_SIZE_OFFSET, instructions, registerTypes)));
			instructions.push(HlInstruction.JumpUnsignedGreaterOrEqual(index, size, slow));
		}
		// An element of an array with validity bits is read only once it was written; else the native raises its error.
		if (hasValidity(arguments[0].type)) {
			var bits = temporaryRegister(IrType.Bytes, registerTypes),
				byte = temporaryRegister(IrType.I32, registerTypes),
				byteIndex = temporaryRegister(IrType.I32, registerTypes),
				bit = temporaryRegister(IrType.I32, registerTypes);
			instructions.push(HlInstruction.GetMem(bits, view.array,
				constantRegister(VALUE_ARRAY_VALIDITY_OFFSET, instructions, registerTypes)));
			instructions.push(HlInstruction.UnsignedShiftRight(byteIndex, index,
				constantRegister(3, instructions, registerTypes)));
			instructions.push(HlInstruction.Add(byteIndex, byteIndex,
				constantRegister(LANE_HEADER_BYTES, instructions, registerTypes)));
			instructions.push(HlInstruction.GetI8(byte, bits, byteIndex));
			instructions.push(HlInstruction.BitAnd(bit, index, constantRegister(7, instructions, registerTypes)));
			instructions.push(HlInstruction.UnsignedShiftRight(byte, byte, bit));
			instructions.push(HlInstruction.BitAnd(byte, byte, constantRegister(1, instructions, registerTypes)));
			instructions.push(HlInstruction.JumpEqual(byte, constantRegister(0, instructions, registerTypes), slow));
		}
		instructions.push(HlInstruction.GetMem(data, view.array,
			constantRegister(ARRAY_DATA_OFFSET, instructions, registerTypes)));
		instructions.push(HlInstruction.Mul(position, index, view.strideBytes));
		// The lane starts with a type word; the payload follows it.
		instructions.push(HlInstruction.Add(position, position,
			constantRegister(LANE_HEADER_BYTES + (slot.offset >> 3), instructions, registerTypes)));
		switch slot.width {
			case 8: instructions.push(HlInstruction.GetI8(destination, data, position));
			case 16: instructions.push(HlInstruction.GetI16(destination, data, position));
			default: instructions.push(HlInstruction.GetMem(destination, data, position));
		}
		if (slot.signed && slot.width < 32) {
			var shift = constantRegister(32 - slot.width, instructions, registerTypes);
			instructions.push(HlInstruction.ShiftLeft(destination, destination, shift));
			instructions.push(HlInstruction.ShiftRight(destination, destination, shift));
		}
		instructions.push(HlInstruction.Jump(done));
		instructions.push(HlInstruction.Label(slow));
		instructions.push(HlInstruction.CallN(destination, requireFunction(VALUE_ARRAY_READ_I32),
			[for (argument in arguments) requireRegister(argument, registers)]));
		instructions.push(HlInstruction.Label(done));
	}

	/** A register holding `value`, loaded where it is asked for. */
	function constantRegister(value:Int, instructions:Array<HlInstruction>, registerTypes:Array<Int>):Int {
		var register = temporaryRegister(IrType.I32, registerTypes);
		instructions.push(HlInstruction.LoadInt(register, internInt(value)));
		return register;
	}

	/**
	 * The value array `array`'s header leads to, as raw memory, and its stride in bytes; null for a header that is no value
	 * array's. A header stays the header it is, and the value array it leads to keeps its identity as it grows, so this is
	 * resolved once per array value within a block (`valueArrayViews`): the value array itself, or a forwarding header's
	 * data (`__value_array_retype`).
	 */
	function valueArrayView(array:IrValue, instructions:Array<HlInstruction>, registers:Array<Int>,
			registerTypes:Array<Int>):ValueArrayView {
		var known = definedViews.get(array.id) ?? valueArrayViews.get(array.id);
		if (known != null)
			return known;
		var view = resolveValueArrayView(array, instructions, registers, registerTypes);
		valueArrayViews.set(array.id, view);
		return view;
	}

	/**
	 * Resolves `array`'s view where the array value is defined (an argument or phi at its block's start, any other value
	 * right after its instruction), so it dominates every read of the value (`definedViews`).
	 */
	function defineValueArrayView(array:IrValue, instructions:Array<HlInstruction>, registers:Array<Int>,
			registerTypes:Array<Int>):Void
		if (hasViewedArrays && viewedArrays.exists(array.id) && !definedViews.exists(array.id))
			definedViews.set(array.id, resolveValueArrayView(array, instructions, registers, registerTypes));

	function resolveValueArrayView(array:IrValue, instructions:Array<HlInstruction>, registers:Array<Int>,
			registerTypes:Array<Int>):ValueArrayView {
		var header = requireRegister(array, registers),
			view:ValueArrayView = {
				array: temporaryRegister(IrType.Bytes, registerTypes),
				strideBytes: temporaryRegister(IrType.I32, registerTypes)
			},
			actual = temporaryRegister(IrType.TypeRef, registerTypes),
			actualPointer = temporaryRegister(IrType.RawPtr, registerTypes),
			expectedPointer = temporaryRegister(IrType.RawPtr, registerTypes),
			forwarded = freshLabel(),
			absent = freshLabel(),
			resolved = freshLabel(),
			strided = freshLabel();
		instructions.push(HlInstruction.GetType(actual, header));
		instructions.push(HlInstruction.UnsafeCast(actualPointer, actual));
		// As pointers: the VM compares type registers structurally, and every array header type is an array type.
		runtimeTypePointer(expectedPointer, VALUE_ARRAY_HEADER_TYPE, instructions, registerTypes);
		instructions.push(HlInstruction.JumpNotEqual(actualPointer, expectedPointer, forwarded));
		instructions.push(HlInstruction.UnsafeCast(view.array, header));
		instructions.push(HlInstruction.Jump(resolved));
		instructions.push(HlInstruction.Label(forwarded));
		runtimeTypePointer(expectedPointer, VALUE_ARRAY_FORWARD_TYPE, instructions, registerTypes);
		instructions.push(HlInstruction.JumpNotEqual(actualPointer, expectedPointer, absent));
		var raw = temporaryRegister(IrType.Bytes, registerTypes);
		instructions.push(HlInstruction.UnsafeCast(raw, header));
		instructions.push(HlInstruction.GetMem(view.array, raw,
			constantRegister(ARRAY_DATA_OFFSET, instructions, registerTypes)));
		instructions.push(HlInstruction.Jump(resolved));
		instructions.push(HlInstruction.Label(absent));
		instructions.push(HlInstruction.LoadNull(view.array));
		instructions.push(HlInstruction.Label(resolved));
		instructions.push(HlInstruction.JumpNull(view.array, strided));
		var strideBits = temporaryRegister(IrType.I32, registerTypes);
		instructions.push(HlInstruction.GetMem(strideBits, view.array,
			constantRegister(VALUE_ARRAY_STRIDE_OFFSET, instructions, registerTypes)));
		instructions.push(HlInstruction.UnsignedShiftRight(view.strideBytes, strideBits,
			constantRegister(3, instructions, registerTypes)));
		instructions.push(HlInstruction.Label(strided));
		return view;
	}

	/** `destination` becomes the runtime type a native names, as a pointer, kept in a global made on first use. */
	function runtimeTypePointer(destination:Int, native:String, instructions:Array<HlInstruction>,
			registerTypes:Array<Int>):Void {
		var type = temporaryRegister(IrType.TypeRef, registerTypes),
			global = internGlobalSlot(native, IrType.TypeRef),
			ready = freshLabel();
		instructions.push(HlInstruction.GlobalGet(type, global));
		instructions.push(HlInstruction.JumpNotNull(type, ready));
		instructions.push(HlInstruction.Call0(type, requireFunction(native)));
		instructions.push(HlInstruction.GlobalSet(global, type));
		instructions.push(HlInstruction.Label(ready));
		instructions.push(HlInstruction.UnsafeCast(destination, type));
	}

	/**
	 * Whether the first instruction from `start` on that is not a constant reads a scalar of the element `validate` checks.
	 * The HashLink runtime's scalar reads validate their element as `__value_array_validate` does, with the same errors, so
	 * a validation right before one adds nothing: a payload-free enum element is read as exactly that pair.
	 */
	static function scalarReadFollows(instructions:Array<compiler.ir.SourceProvenance.Located<compiler.ir.Ir.IrInstruction>>,
			start:Int, validate:Array<IrValue>):Bool {
		if (validate.length != 2)
			return false;
		for (position in start...instructions.length)
			switch instructions[position].value {
				case ConstInt(_, _), ConstBool(_, _):
				case Call(_, name, arguments):
					return StringTools.startsWith(name.name, "__value_array_read_") && arguments.length >= 2
						&& arguments[0].id == validate[0].id && arguments[1].id == validate[1].id;
				default:
					return false;
			}
		return false;
	}

	static function rawArrayShift(array:IrType):Null<Int>
		return switch array {
			case Array(I32): 2;
			case Array(F64): 3;
			default: null;
		};

	static function rawArrayNativeName(array:IrType, operation:String):String
		return '__hl_array_${operation}_${rawArrayShift(array) == 2 ? "i32" : "f64"}';

	/**
	 * The out-of-range paths of an inlined array access: `array_out_of_bounds` for a read and `array_ensure` for a write.
	 * The native declaration marks array_out_of_bounds as non-returning. The JIT loads that callee property from
	 * its library, so values stay in registers across the bounds test. array_ensure remains an ordinary call.
	 */
	static function ensureRawArrayNative(natives:Array<IrNative>, array:IrType, operation:String):Void {
		if (rawArrayShift(array) != null)
			ensureNative(natives, rawArrayNativeName(array, operation), [array, IrType.I32], IrType.Void, "std",
				operation == "check" ? "array_out_of_bounds" : 'array_$operation');
	}

	/** Float and Int elements are read in place; every other element type is boxed and cast back. */
	static function iteratorNextNative(element:IrType):{name:String, result:IrType} return switch element {
		case F64: {name: "__iterator_next_f64", result: IrType.F64};
		case I32: {name: "__iterator_next_i32", result: IrType.I32};
		default: {name: "__iterator_next", result: IrType.Dyn};
	};

	static function ensureNative(natives:Array<IrNative>, name:String, arguments:Array<IrType>, result:IrType,
			?library:String, ?symbol:String):Void {
		var nativeLibrary = library == null ? "haxeon_runtime" : library,
			nativeSymbol = symbol == null ? name : symbol;
		for (native in natives)
			if (native.name == name) {
				if (native.arguments.length != arguments.length
					|| !IrTypeIdentity.same(native.result, result)
					|| native.library != nativeLibrary
					|| native.symbol != nativeSymbol)
					throw new InternalError('Conflicting HashLink runtime native signature for "$name": ${native.arguments} -> ${native.result}, expected $arguments -> $result');
				for (index in 0...arguments.length)
					if (Std.string(native.arguments[index]) != Std.string(arguments[index]))
						throw new InternalError('Conflicting HashLink runtime native signature for "$name": ${native.arguments} -> ${native.result}, expected $arguments -> $result');
				return;
			}
		natives.push({
			name: name,
			library: nativeLibrary,
			symbol: nativeSymbol,
			arguments: arguments,
			result: result
		});
	}

	function lowerNative(native:IrNative):Void {
		code.natives.push({
			library: internString(native.library),
			name: internString(native.symbol),
			type: internFunctionType(StringTools.startsWith(native.name, "$scalar-closure:receiver:")
				&& native.symbol == "__closure_receiver_if_match" ? [
					Dyn,
					Dyn
				] : native.arguments,
				native.result),
			functionIndex: requireFunction(native.name),
		});
	}

	function lowerFunction(fn:IrFunction):HlFunction {
		nextLabel = 0;
		for (block in fn.blocks)
			if (block.id >= nextLabel)
				nextLabel = block.id + 1;
		// Both read the function as it is, so they share its graph.
		var graph = new compiler.ir.IrGraph(fn),
			nonNull = new compiler.ir.IrNonNullFacts(fn, true, graph, nonNullScratch),
			exactTypes = new compiler.ir.IrExactTypeFacts(fn, graph);
		// Tables about values are indexed by value id, which is dense within a function: a register (-1 before its
		// definition), whether the value is a null constant, and how many operands read it.
		var registers = valueRegisters;
		registers.resize(0);
		var registerTypes:Array<Int> = [];
		var catchValues:Map<Int, IrValue> = [];
		var nullValues = valueIsNull;
		nullValues.resize(0);
		for (argument in fn.arguments)
			defineRegister(argument, registers, registerTypes);
		for (block in fn.blocks)
			for (instruction in block.instructions) {
				var output = instructionOutput(instruction.value);
				if (output != null)
					defineRegister(output, registers, registerTypes);
				switch instruction.value {
					case ConstNull(value):
						while (nullValues.length <= value.id)
							nullValues.push(false);
						nullValues[value.id] = true;
					case _:
				}
			}
		var scalarOptionals = new HlScalarValueLocals(fn, view, type -> temporaryRegister(type, registerTypes));
		var uses = valueUses;
		uses.resize(0);
		function countUse(value:IrValue):Void {
			while (uses.length <= value.id)
				uses.push(0);
			uses[value.id]++;
		}
		function usedOnce(value:IrValue):Bool
			return value.id < uses.length && uses[value.id] == 1;
		function isNullConstant(value:IrValue):Bool
			return value.id < nullValues.length && nullValues[value.id];
		for (block in fn.blocks) {
			for (instruction in block.instructions) {
				for (inputIndex in 0...compiler.ir.IrOperands.count(instruction.value)) {
					var input = compiler.ir.IrOperands.at(instruction.value, inputIndex);
					countUse(input);
				}
				switch instruction.value {
					case Phi(_, inputs):
						for (input in inputs)
							countUse(input.value);
					default:
				}
			}
			if (block.terminator != null)
				switch block.terminator.value {
					case Return(value), Throw(value), Rethrow(value), Branch(value, _, _), Switch(value, _, _):
						countUse(value);
					case Jump(_), Unreachable:
				}
		}
		// An array boxed only to be cast back to an array, as a coercion between array types does, is the same HashLink array
		// (`HlType.Array` carries no element type): the cast takes the array itself unchecked, and the box is not made.
		var arrayRecasts:Map<Int, IrValue> = [], unboxedArrays:Map<Int, Bool> = [];
		for (block in fn.blocks)
			for (index in 0...block.instructions.length - 1)
				switch block.instructions[index].value {
					case ToDyn(boxed, value) if (isArray(value.type) && usedOnce(boxed)):
						switch block.instructions[index + 1].value {
							case SafeCast(output, source) if (source.id == boxed.id && isArray(output.type)):
								arrayRecasts.set(output.id, value);
								unboxedArrays.set(boxed.id, true);
							default:
						}
					default:
				}
		var edges:Map<Int, Map<Int, Array<{destination:IrValue, source:IrValue}>>> = [];
		for (block in fn.blocks)
			for (instruction in block.instructions)
				switch instruction.value {
					case Phi(output, inputs):
						defineRegister(output, registers, registerTypes);
						for (input in inputs) {
							var from = edges.get(input.block);
							if (from == null) {
								from = [];
								edges.set(input.block, from);
							}
							var moves = from.get(block.id);
							if (moves == null) {
								moves = [];
								from.set(block.id, moves);
							}
							moves.push({destination: output, source: input.value});
						}
					case Catch(output):
						catchValues.set(block.id, output);
						defineRegister(output, registers, registerTypes);
					default:
				}

		var bindingsByValue:Map<Int, Array<compiler.ir.IrFunction.IrDebugBinding>> = [];
		for (binding in fn.debugBindings) {
			var bindings = bindingsByValue.get(binding.value.id);
			if (bindings == null) {
				bindings = [];
				bindingsByValue.set(binding.value.id, bindings);
			}
			bindings.push(binding);
		}
		var debugAssignments:Array<HlDebugAssignment> = [],
			assignmentBindings:Array<compiler.ir.IrFunction.IrDebugBinding> = [],
			seenAssignments:Map<String, Bool> = [];
		for (argument in fn.arguments) {
			var bindings = bindingsByValue.get(argument.id);
			if (bindings != null)
				for (binding in bindings) {
					debugAssignments.push({name: internString(binding.name), position: -1, scopeEnd: -1});
					assignmentBindings.push(binding);
				}
		}
		// The array values read inline get their value array view where they are defined (`defineValueArrayView`).
		viewedArrays.clear();
		definedViews.clear();
		hasViewedArrays = false;
		loweringFunction = fn;
		loopBounds = null;
		for (block in fn.blocks)
			for (index in 0...block.instructions.length)
				switch block.instructions[index].value {
					case Call(_, name, arguments) if (name.name == VALUE_ARRAY_READ_I32
						&& inlineValueArraySlot(block.instructions, index, arguments) != null):
						viewedArrays.set(arguments[0].id, true);
						hasViewedArrays = true;
					default:
				}
		var instructions = instructionScratch, debugLocations = locationScratch;
		instructions.resize(0);
		debugLocations.resize(0);
		// A jump to the block written next is left out: control falls through to it.
		var emitted = [
			for (block in orderedBlocks(fn))
				if (block.instructions.length > 0 || block.terminator != null) block
		];
		var layoutPositions:Map<Int, Int> = [for (index in 0...emitted.length) emitted[index].id => index];
		for (layoutIndex in 0...emitted.length) {
			var block = emitted[layoutIndex],
				fallsThroughTo = layoutIndex + 1 < emitted.length ? emitted[layoutIndex + 1].id : -1;
			instructions.push(HlInstruction.Label(block.id));
			debugLocations.push(debugLocation(blockProvenance(block)));
			// Arguments and phis are defined when the block starts: their value array views are resolved here.
			if (hasViewedArrays) {
				var viewStart = instructions.length;
				if (block == fn.blocks[0])
					for (argument in fn.arguments)
						defineValueArrayView(argument, instructions, registers, registerTypes);
				for (located in block.instructions)
					switch located.value {
						case Phi(output, _): defineValueArrayView(output, instructions, registers, registerTypes);
						default:
					}
				appendDebugLocations(debugLocations, instructions.length - viewStart, blockProvenance(block));
			}
			// A comparison that ends its block and feeds only that block's branch becomes the branch itself, with
			// no Bool in between: the loop test then costs one compare-and-jump instead of a compare, two moves and a test.
			var fusedCondition:Null<Int> = null,
				fusedComparison:Null<HlInstruction> = null,
				fusedFloat = false;
			if (block.terminator != null && block.instructions.length > 0)
				switch block.terminator.value {
					case Branch(condition, _,
						_) if (usedOnce(condition) && !bindingsByValue.exists(condition.id)):
						switch block.instructions[block.instructions.length - 1].value {
							case Less(output, _, _), LessEqual(output, _, _),
								Equal(output, _, _) if (output.id == condition.id):
								fusedCondition = condition.id;
							case Call(output, name, arguments) if (output.id == condition.id && arguments.length == 2
								&& (name.name == compiler.ir.IrExactTypeFacts.TEST
								|| name.name == compiler.ir.IrReferenceIdentity.NAME)):
								fusedCondition = condition.id;
							default:
						}
					default:
				}
			provenInRange.clear();
			elementOffsets.clear();
			valueArrayViews.clear();
			validatedArrayAccesses.clear();
			for (instructionIndex in 0...block.instructions.length) {
				var instruction = block.instructions[instructionIndex];
				var instructionStart = instructions.length;
				if (!keepsArrayBounds(instruction.value))
					provenInRange.clear();
				var output = instructionOutput(instruction.value);
				// Native field/enum/array loads cannot turn a hardware fault into a Haxe exception.
				// Emit an explicit check so the active handler works on every thread.
				var receiver:Null<IrValue> = switch instruction.value {
					case FieldGet(_, value, _), FieldSet(value, _, _), MethodCall(_, value, _, _, _),
						InstanceClosure(_, _, value), ArrayGet(_, value, _),
						ArraySet(value, _, _), ArraySize(_, value), IteratorNew(_, value), IteratorHasNext(_, value),
						IteratorNext(_, value),
						EnumIndex(_, value), EnumField(_, value, _, _): value;
					case _: null;
				};
				if (receiver != null && scalarOptionals.get(receiver) == null
					&& !nonNull.has(block.id, instructionIndex))
					instructions.push(HlInstruction.NullCheck(requireRegister(receiver, registers)));
				switch instruction.value {
					case Phi(_, _):
					case ClassId(_, _):
						throw new InternalError('internal error: ClassId is lowered by the interface dispatch (docs/design/INTERFACE_VALUES.md), which HashLink does not have yet');
					case ConstVoid(output):
						defineRegister(output, registers, registerTypes);
					case ConstInt(output, value):
						instructions.push(HlInstruction.LoadInt(defineRegister(output, registers, registerTypes),
							internInt(value)));
					case ConstFloat(output, value):
						instructions.push(HlInstruction.LoadFloat(defineRegister(output, registers, registerTypes),
							internFloat(value)));
					case ConstString(output, value):
						lowerStringLiteral(defineRegister(output, registers, registerTypes), value, registerTypes,
							instructions);
					case StaticDataAddress(output, _):
						// RuntimeData is a Wasm-only intrinsic. The HashLink shadow module is
						// still assembled for a Wasm compilation, but never executes this path.
						instructions.push(HlInstruction.LoadInt(defineRegister(output, registers, registerTypes),
							internInt(0)));
					case PointerOffset(output, pointer, byteOffset):
						instructions.push(HlInstruction.Call2(defineRegister(output, registers, registerTypes),
							requireFunction("__hl_bytes_offset"),
							requireRegister(pointer, registers), requireRegister(byteOffset, registers)));
					case MemoryLoad(output, pointer, size, signed):
						var destination = defineRegister(output, registers, registerTypes),
							zeroOffset = temporaryRegister(IrType.I32, registerTypes);
						instructions.push(HlInstruction.LoadInt(zeroOffset, internInt(0)));
						if (size == 1)
							instructions.push(HlInstruction.GetI8(destination, requireRegister(pointer, registers),
								zeroOffset));
						else if (size == 2)
							instructions.push(HlInstruction.GetI16(destination, requireRegister(pointer, registers),
								zeroOffset));
						else
							instructions.push(HlInstruction.GetMem(destination, requireRegister(pointer, registers),
								zeroOffset));
						if (signed && size < 4) {
							var shift = temporaryRegister(IrType.I32, registerTypes),
								shiftCount = internInt(size == 1 ? 24 : 16);
							instructions.push(HlInstruction.LoadInt(shift, shiftCount));
							instructions.push(HlInstruction.ShiftLeft(destination, destination, shift));
							instructions.push(HlInstruction.ShiftRight(destination, destination, shift));
						}
					case MemoryStore(pointer, value, size):
						var zeroOffset = temporaryRegister(IrType.I32, registerTypes);
						instructions.push(HlInstruction.LoadInt(zeroOffset, internInt(0)));
						if (size == 1)
							instructions.push(HlInstruction.SetI8(requireRegister(pointer, registers), zeroOffset,
								requireRegister(value, registers)));
						else if (size == 2)
							instructions.push(HlInstruction.SetI16(requireRegister(pointer, registers), zeroOffset,
								requireRegister(value, registers)));
						else
							instructions.push(HlInstruction.SetMem(requireRegister(pointer, registers), zeroOffset,
								requireRegister(value, registers)));
					case ConstBool(output, value):
						instructions.push(HlInstruction.LoadBool(defineRegister(output, registers, registerTypes),
							value));
					case ConstNull(output):
						switch output.type {
							case EnumTag(_): instructions.push(HlInstruction.LoadInt(defineRegister(output, registers,
								registerTypes), internInt(0)));
							default: instructions.push(HlInstruction.LoadNull(defineRegister(output, registers,
								registerTypes)));
						}
					case TypeValue(output, type):
						instructions.push(HlInstruction.LoadType(defineRegister(output, registers, registerTypes),
							internType(type)));
					case ToDyn(output, _) if (unboxedArrays.exists(output.id) && !bindingsByValue.exists(output.id)):
					case ToDyn(output, value):
						instructions.push(HlInstruction.ToDyn(defineRegister(output, registers, registerTypes),
							requireRegister(value, registers)));
					case IntToFloat(output, value):
						instructions.push(HlInstruction.ToSFloat(defineRegister(output, registers, registerTypes),
							requireRegister(value, registers)));
					case IntToInt64(output, value):
						instructions.push(HlInstruction.ToInt(defineRegister(output, registers, registerTypes),
							requireRegister(value, registers)));
					case FloatToInt(output, value):
						instructions.push(HlInstruction.ToInt(defineRegister(output, registers, registerTypes),
							requireRegister(value, registers)));
					case FloatToFloat(output, value):
						instructions.push(HlInstruction.ToSFloat(defineRegister(output, registers, registerTypes),
							requireRegister(value, registers)));
					case SafeCast(output, value):
						var array = arrayRecasts.get(output.id);
						if (array != null && !bindingsByValue.exists(value.id))
							instructions.push(HlInstruction.UnsafeCast(defineRegister(output, registers, registerTypes),
								requireRegister(array, registers)));
						else if (switch output.type {
							case Obj(name): exactTypes.exactType(block.id, value.id) == name;
							default: false;
						})
							// A dominating exact-class test proved the value an object of exactly this class.
							instructions.push(HlInstruction.UnsafeCast(defineRegister(output, registers, registerTypes),
							requireRegister(value, registers)));
						else
							instructions.push(HlInstruction.SafeCast(defineRegister(output, registers, registerTypes),
								requireRegister(value, registers)));
					case BeginTry(catchBlock, _, preserveExceptionStack):
						if (!catchValues.exists(catchBlock))
							throw new InternalError('Try block $block.id has no catch value in block $catchBlock');
						var handlerValue = catchValues.get(catchBlock);
						var handlerRegister = requireRegister(handlerValue, registers);
						instructions.push(HlInstruction.Trap(handlerRegister, catchBlock,
							preserveExceptionStack));
					case EndTry(catchBlock, preserveExceptionStack):
						if (!catchValues.exists(catchBlock))
							throw new InternalError('Try block $block.id ends with unknown handler block $catchBlock');
						instructions.push(HlInstruction.EndTrap(requireRegister(catchValues.get(catchBlock), registers),
							preserveExceptionStack));
					case Catch(_):
					case GlobalGet(output, name):
						var global = requireGlobal(name);
						instructions.push(HlInstruction.GlobalGet(defineRegister(output, registers, registerTypes),
							global));
					case GlobalSet(name, source):
						var global = requireGlobal(name);
						instructions.push(HlInstruction.GlobalSet(global, requireRegister(source, registers)));
					case Add(output, left, right):
						instructions.push(HlInstruction.Add(defineRegister(output, registers, registerTypes),
							requireRegister(left, registers),
							requireRegister(right, registers)));
					case Sub(output, left, right):
						instructions.push(HlInstruction.Sub(defineRegister(output, registers, registerTypes),
							requireRegister(left, registers),
							requireRegister(right, registers)));
					case Mul(output, left, right):
						instructions.push(HlInstruction.Mul(defineRegister(output, registers, registerTypes),
							requireRegister(left, registers),
							requireRegister(right, registers)));
					case Div(output, left, right):
						instructions.push(HlInstruction.Div(defineRegister(output, registers, registerTypes),
							requireRegister(left, registers),
							requireRegister(right, registers)));
					case Mod(output, left, right):
						instructions.push(HlInstruction.Mod(defineRegister(output, registers, registerTypes),
							requireRegister(left, registers),
							requireRegister(right, registers)));
					case BitAnd(output, left, right):
						instructions.push(HlInstruction.BitAnd(defineRegister(output, registers, registerTypes),
							requireRegister(left, registers),
							requireRegister(right, registers)));
					case BitXor(output, left, right):
						instructions.push(HlInstruction.BitXor(defineRegister(output, registers, registerTypes),
							requireRegister(left, registers),
							requireRegister(right, registers)));
					case BitOr(output, left, right):
						instructions.push(HlInstruction.BitOr(defineRegister(output, registers, registerTypes),
							requireRegister(left, registers),
							requireRegister(right, registers)));
					case ShiftLeft(output, left, right):
						instructions.push(HlInstruction.ShiftLeft(defineRegister(output, registers, registerTypes),
							requireRegister(left, registers),
							requireRegister(right, registers)));
					case ShiftRight(output, left, right):
						instructions.push(HlInstruction.ShiftRight(defineRegister(output, registers, registerTypes),
							requireRegister(left, registers),
							requireRegister(right, registers)));
					case UnsignedShiftRight(output, left, right):
						instructions.push(HlInstruction.UnsignedShiftRight(defineRegister(output, registers,
							registerTypes), requireRegister(left, registers),
							requireRegister(right, registers)));
					case Less(output, left, right) if (output.id == fusedCondition):
						fusedFloat = isFloat(left.type) || isFloat(right.type);
						fusedComparison = comparisonJump(0, false, false, requireRegister(left, registers),
							requireRegister(right, registers), -1);
					case LessEqual(output, left, right) if (output.id == fusedCondition):
						fusedFloat = isFloat(left.type) || isFloat(right.type);
						fusedComparison = comparisonJump(1, false, false, requireRegister(left, registers),
							requireRegister(right, registers), -1);
					case Equal(output, left, right) if (output.id == fusedCondition):
						fusedComparison = comparisonJump(2, isNullConstant(left), isNullConstant(right),
							requireRegister(left, registers),
							requireRegister(right, registers), -1);
					case Less(output, left, right):
						lowerComparison(output, left, right, 0, false, false, registers, registerTypes, instructions);
					case LessEqual(output, left, right):
						lowerComparison(output, left, right, 1, false, false, registers, registerTypes, instructions);
					case Equal(output, left, right):
						lowerComparison(output, left, right, 2, isNullConstant(left), isNullConstant(right),
							registers, registerTypes,
							instructions);
					case Intrinsic(_, _, _):
						throw new InternalError("Unlowered IR intrinsic reached HashLink");
					case Call(output, functionName, arguments) if (output.id == fusedCondition
						&& functionName.name == compiler.ir.IrReferenceIdentity.NAME):
						// A reference-identity test ending its block: compare the two pointers and jump, with no Bool.
						var pointers = identityPointers(arguments, instructions, registers, registerTypes);
						fusedComparison = comparisonJump(2, false, false, pointers[0], pointers[1], -1);
					case Call(output, functionName, arguments) if (output.id == fusedCondition):
						// The exact-class test ending its block: compare the object's type pointer and jump, with no Bool.
						var actual = temporaryRegister(IrType.TypeRef, registerTypes);
						instructions.push(HlInstruction.GetType(actual, requireRegister(arguments[0], registers)));
						fusedComparison = comparisonJump(2, false, false, actual,
							requireRegister(arguments[1], registers), -1);
					case Call(output, functionName, arguments):
						var inlineSlot = functionName.name == VALUE_ARRAY_READ_I32
							? inlineValueArraySlot(block.instructions, instructionIndex, arguments) : null;
						if (functionName.name == compiler.ir.IrReceiverCheck.NAME
							&& nonNull.has(block.id, instructionIndex)) {
							// A previous successful dereference or check already proved this SSA receiver non-null.
						} else if (functionName.name == VALUE_ARRAY_VALIDATE
							&& scalarReadFollows(block.instructions, instructionIndex + 1, arguments)) {
							// The read checks the same element the same way (`realtime_value_array_check_read`).
						} else if (inlineSlot != null) {
							lowerValueArrayRead(output, arguments, inlineSlot, block.id, instructions, registers,
								registerTypes);
						} else if (!lowerRuntimeFastPath(output, functionName.name, arguments, instructions, registers,
							registerTypes)) {
							var destination = defineRegister(output, registers, registerTypes);
							var functionIndex = requireFunction(functionName.name);
							var args = [for (argument in arguments) requireRegister(argument, registers)];
							if (StringTools.startsWith(functionName.name, "$scalar-closure:receiver:"))
								for (index in 0...arguments.length)
									switch arguments[index].type {
										case Function(_, _):
											var dynamicClosure = temporaryRegister(IrType.Dyn, registerTypes);
											instructions.push(HlInstruction.ToDyn(dynamicClosure, args[index]));
											args[index] = dynamicClosure;
										default:
									}
							switch args.length {
								case 0: instructions.push(HlInstruction.Call0(destination, functionIndex));
								case 1: instructions.push(HlInstruction.Call1(destination, functionIndex, args[0]));
								case 2: instructions.push(HlInstruction.Call2(destination, functionIndex, args[0],
									args[1]));
								default: instructions.push(HlInstruction.CallN(destination, functionIndex, args));
							}
						}
					case IteratorNew(output, array):
						var destination = defineRegister(output, registers, registerTypes),
							boxedArray = temporaryRegister(IrType.Dyn, registerTypes);
						instructions.push(HlInstruction.ToDyn(boxedArray, requireRegister(array, registers)));
						instructions.push(HlInstruction.Call1(destination, requireFunction("__iterator_new"),
							boxedArray));
					case IteratorHasNext(output, iterator):
						instructions.push(HlInstruction.Call1(defineRegister(output, registers, registerTypes),
							requireFunction("__iterator_has_next"),
							requireRegister(iterator, registers)));
					case IteratorNext(output, iterator):
						var destination = defineRegister(output, registers, registerTypes),
							nextNative = iteratorNextNative(output.type);
						if ((switch (nextNative.result) {
							case IrType.Dyn: true;
							default: false;
						})) {
							var dynamicResult = temporaryRegister(IrType.Dyn, registerTypes);
							instructions.push(HlInstruction.Call1(dynamicResult, requireFunction(nextNative.name),
								requireRegister(iterator, registers)));
							instructions.push(HlInstruction.SafeCast(destination, dynamicResult));
						} else
							instructions.push(HlInstruction.Call1(destination, requireFunction(nextNative.name),
								requireRegister(iterator, registers)));
					case CNativeCall(output, functionName, arguments):
						var native = cNatives.get(functionName);
						if (native == null)
							throw new InternalError('Unknown ordinary C function "$functionName"');
						for (type in native.arguments)
							if (unsupportedCDispatchArgument(type))
								throw new InternalError('Ordinary C function "$functionName" uses an unsupported executable argument type $type');
						if ((switch (native.result) {
							case Void: false;
							default: true;
						}) && unsupportedCDispatchResult(native.result))
							throw new InternalError('Ordinary C function "$functionName" uses an unsupported executable result type ${native.result}');
						var callArguments = [
							temporaryRegister(IrType.RawPtr, registerTypes),
							temporaryRegister(IrType.RawPtr, registerTypes),
							temporaryRegister(IrType.RawPtr, registerTypes)
						];
						instructions.push(HlInstruction.LoadString(callArguments[0], internString(native.library)));
						instructions.push(HlInstruction.LoadString(callArguments[1], internString(native.symbol)));
						instructions.push(HlInstruction.LoadString(callArguments[2], internString(native.signature)));
						var pointerResult = isNativePointer(native.result),
							bytesResult = isManagedPointerBytes(native),
							aggregateResult = isAggregateResult(native),
							utf8Result = isUtf8Result(native);
						if (pointerResult || bytesResult || utf8Result) {
							var ownership = temporaryRegister(IrType.RawPtr, registerTypes),
								release = temporaryRegister(IrType.RawPtr, registerTypes),
								nullable = temporaryRegister(IrType.Bool, registerTypes);
							instructions.push(HlInstruction.LoadString(ownership,
								internString(native.pointerOwnership)));
							instructions.push(HlInstruction.LoadString(release,
								internString(native.pointerRelease == null ? "" : native.pointerRelease)));
							instructions.push(HlInstruction.LoadBool(nullable, native.pointerNullable));
							callArguments.push(ownership);
							callArguments.push(release);
							if (bytesResult) {
								var length = temporaryRegister(IrType.RawPtr, registerTypes);
								instructions.push(HlInstruction.LoadString(length, internString(native.pointerLength)));
								callArguments.push(length);
							}
							callArguments.push(nullable);
						}
						for (argument in arguments) {
							var boxed = temporaryRegister(IrType.Dyn, registerTypes);
							if (isNullConstant(argument))
								instructions.push(HlInstruction.LoadNull(boxed));
							else
								instructions.push(HlInstruction.ToDyn(boxed, requireRegister(argument, registers)));
							callArguments.push(boxed);
						}
						var dynamicResult = temporaryRegister(pointerResult
							? IrType.Abstract("native_pointer") : (bytesResult || aggregateResult)
							? IrType.ManagedBytes : utf8Result ? IrType.Bytes : IrType.Dyn,
							registerTypes);
						instructions.push(HlInstruction.CallN(dynamicResult,
							requireFunction(pointerResult ? '__c_native_pointer_invoke_${arguments.length}'
							: bytesResult ? '__c_native_bytes_invoke_${arguments.length}' : aggregateResult
							? '__c_native_aggregate_invoke_${arguments.length}' : utf8Result
							? '__c_native_utf8_invoke_${arguments.length}' : '__c_native_invoke_${arguments.length}'),
							callArguments));
						if ((switch (native.result) {
							case Void: true;
							default: false;
						}))
							defineRegister(output, registers, registerTypes);
						else if (pointerResult || bytesResult || aggregateResult || utf8Result)
							instructions.push(HlInstruction.Move(defineRegister(output, registers, registerTypes),
								dynamicResult));
						else
							instructions.push(HlInstruction.SafeCast(defineRegister(output, registers, registerTypes),
								dynamicResult));
					case StaticClosure(output, functionName):
						instructions.push(HlInstruction.StaticClosure(defineRegister(output, registers, registerTypes),
							requireFunction(functionName.name)));
					case InstanceClosure(output, functionName, receiver):
						instructions.push(HlInstruction.InstanceClosure(defineRegister(output, registers,
							registerTypes), requireFunction(functionName.name),
							requireRegister(receiver, registers)));
					case CallClosure(output, closure, arguments):
						instructions.push(HlInstruction.NullCheck(requireRegister(closure, registers)));
						if ((switch (closure.type) {
							case IrType.Dyn: true;
							default: false;
						})) {
							var callable = temporaryRegister(IrType.Bool, registerTypes),
								error = temporaryRegister(IrType.Bytes, registerTypes),
								valid = freshLabel();
							instructions.push(HlInstruction.Call1(callable, requireFunction("__reflect_is_function"),
								requireRegister(closure, registers)));
							instructions.push(HlInstruction.JumpTrue(callable, valid));
							lowerStringLiteral(error, "Cannot call a non-function value", registerTypes, instructions);
							instructions.push(HlInstruction.Throw(error));
							instructions.push(HlInstruction.Label(valid));
						}
						instructions.push(HlInstruction.CallClosure(defineRegister(output, registers, registerTypes),
							requireRegister(closure, registers),
							[for (argument in arguments) requireRegister(argument, registers)]));
					case Upcast(output, value):
						// HashLink accepts a subclass register wherever its base class is expected.
						instructions.push(HlInstruction.Move(defineRegister(output, registers, registerTypes),
							requireRegister(value, registers)));
					case ToVirtual(output, value):
						instructions.push(HlInstruction.ToVirtual(defineRegister(output, registers, registerTypes),
							requireRegister(value, registers)));
					case MethodCall(output, object, methodName, arguments, _):
						var receiver = requireRegister(object, registers),
							methodArguments =
								[receiver].concat([for (argument in arguments) requireRegister(argument, registers)]),
							valueMethod = valueMethodFunction(object, methodName);
						if (valueMethod == null)
							valueMethod = addedMethodFunction(object, methodName);
						if (valueMethod != null) {
							// A value class has no prototype to dispatch through and cannot be subclassed, so its methods are direct calls,
							// as are methods a live patch added.
							var destination = defineRegister(output, registers, registerTypes),
								functionIndex = requireFunction(valueMethod);
							switch methodArguments.length {
								case 1: instructions.push(HlInstruction.Call1(destination, functionIndex,
									methodArguments[0]));
								case 2: instructions.push(HlInstruction.Call2(destination, functionIndex,
									methodArguments[0], methodArguments[1]));
								default: instructions.push(HlInstruction.CallN(destination, functionIndex,
									methodArguments));
							}
						} else
							instructions.push(HlInstruction.CallMethod(defineRegister(output, registers, registerTypes),
								requireObjectMethod(object, methodName), methodArguments));
					case ValueInit(output) if (scalarOptionals.get(output) != null):
						var local:HlScalarValueLocal = cast scalarOptionals.get(output);
						for (field in local.declarations) {
							var target:Int = cast local.fields.get(field.name);
							switch field.type {
								case Bool: instructions.push(HlInstruction.LoadBool(target, false));
								case I32, I64: instructions.push(HlInstruction.LoadInt(target, internInt(0)));
								case F32, F64: instructions.push(HlInstruction.LoadFloat(target, internFloat(0.0)));
								default: instructions.push(HlInstruction.LoadNull(target));
							}
						}
					case NewObject(output, typeName):
						instructions.push(HlInstruction.New(defineRegister(output, registers, registerTypes),
							requireObjectType(typeName), 0));
					case ValueInit(output):
						instructions.push(HlInstruction.New(defineRegister(output, registers, registerTypes),
							requireObjectType(compiler.ir.IrTypeTools.valueObjectName(output.type)), 0));
					case FieldGet(output, object, fieldName) if (scalarOptionals.get(object) != null):
						var local:HlScalarValueLocal = cast scalarOptionals.get(object);
						var source:Int = cast local.fields.get(fieldName);
						instructions.push(HlInstruction.Move(defineRegister(output, registers, registerTypes), source));
					case FieldGet(output, object, fieldName):
						var destination = defineRegister(output, registers, registerTypes),
							nativeLayout = objectFieldNativeLayout(object, fieldName),
							storageType = internNativeStorage(output.type, nativeLayout);
						if ((switch (output.type) {
							case I64: true;
							default: false;
						}) && storageType != null) {
							var stored = temporaryRegisterType(storageType, registerTypes);
							instructions.push(HlInstruction.FieldGet(stored, requireRegister(object, registers),
								requireObjectField(object, fieldName)));
							instructions.push(HlInstruction.ToInt(destination, stored));
							if (nativeLayout != null && !nativeLayout.signed) {
								var shift = temporaryRegister(IrType.I32, registerTypes);
								instructions.push(HlInstruction.LoadInt(shift, internInt(32)));
								instructions.push(HlInstruction.ShiftLeft(destination, destination, shift));
								instructions.push(HlInstruction.UnsignedShiftRight(destination, destination, shift));
							}
						} else
							instructions.push(HlInstruction.FieldGet(destination, requireRegister(object, registers),
								requireObjectField(object, fieldName)));
						// Inline records produce an HSTRUCT pointer into their owner. Only scalar
						// narrow fields need sign or zero extension after the field load.
						if (nativeLayout != null && nativeLayout.size < 4) {
							var maskOrShift = temporaryRegister(IrType.I32, registerTypes),
								bits = nativeLayout.size * 8;
							instructions.push(HlInstruction.LoadInt(maskOrShift,
								internInt(nativeLayout.signed ? 32 - bits : (1 << bits) - 1)));
							if (nativeLayout.signed) {
								instructions.push(HlInstruction.ShiftLeft(destination, destination, maskOrShift));
								instructions.push(HlInstruction.ShiftRight(destination, destination, maskOrShift));
							} else
								instructions.push(HlInstruction.BitAnd(destination, destination, maskOrShift));
						}
					case FieldSet(object, fieldName, value) if (scalarOptionals.get(object) != null):
						var local:HlScalarValueLocal = cast scalarOptionals.get(object);
						var destination:Int = cast local.fields.get(fieldName);
						instructions.push(HlInstruction.Move(destination, requireRegister(value, registers)));
					case FieldSet(object, fieldName, value):
						var receiver = requireRegister(object, registers),
							field = requireObjectField(object, fieldName),
							source = requireRegister(value, registers),
							nativeStorageType = internNativeStorage(value.type,
								objectFieldNativeLayout(object, fieldName));
						if (nativeStorageType != null) {
							var storageSource = temporaryRegisterType(nativeStorageType, registerTypes);
							instructions.push(HlInstruction.ToInt(storageSource, source));
							source = storageSource;
						}
						instructions.push(HlInstruction.FieldSet(receiver, field, source));
					case ArrayGet(output, array, index) if (rawArrayShift(array.type) != null):
						instructions.push(HlInstruction.ArrayGet(defineRegister(output, registers, registerTypes),
							requireRegister(array, registers),
							requireRegister(index, registers)));
						var key = '${array.id}:${index.id}';
						provenInRange.set(key, true);
						validatedArrayAccesses.set(key, true);
					case ArraySet(array, index, value) if (rawArrayShift(array.type) != null):
						var source = requireRegister(value, registers);
						lowerRawArrayAccess(array, index, "ensure", true, instructions, registers, registerTypes,
							(data, offset) -> HlInstruction.SetMem(data, offset, source));
					case ArrayGet(output, array, index):
						instructions.push(HlInstruction.ArrayGet(defineRegister(output, registers, registerTypes),
							requireRegister(array, registers),
							requireRegister(index, registers)));
					case ArraySet(array, index, value):
						instructions.push(HlInstruction.ArraySet(requireRegister(array, registers),
							requireRegister(index, registers),
							requireRegister(value, registers)));
					case ArraySize(output, array):
						instructions.push(HlInstruction.ArraySize(defineRegister(output, registers, registerTypes),
							requireRegister(array, registers)));
					case MakeEnum(output, _, constructor, _) if (switch output.type {
						case EnumTag(_): true;
						default: false;
					}): instructions.push(HlInstruction.LoadInt(defineRegister(output, registers, registerTypes),
						internInt(constructor + 1)));
					case MakeEnum(output, typeName, constructor, arguments):
						var destination = defineRegister(output, registers, registerTypes),
							enumConstructor = requireEnumConstructor(typeName, output.type, constructor),
							args = [for (argument in arguments) requireRegister(argument, registers)];
						if (args.length == 0)
							lowerEnumConstant(destination, typeName, enumConstructor, instructions);
						else
							instructions.push(HlInstruction.MakeEnum(destination, enumConstructor, args));
					case EnumIndex(output, value) if (switch value.type {
						case EnumTag(_): true;
						default: false;
					}): var one = temporaryRegister(IrType.I32, registerTypes);
					instructions.push(HlInstruction.LoadInt(one, internInt(1)));
					instructions.push(HlInstruction.Sub(defineRegister(output, registers, registerTypes),
						requireRegister(value, registers), one));
					case EnumIndex(output, value):
						instructions.push(HlInstruction.EnumIndex(defineRegister(output, registers, registerTypes),
							requireRegister(value, registers)));
					case EnumField(output, value, constructor, field):
						instructions.push(HlInstruction.EnumField(defineRegister(output, registers, registerTypes),
							requireRegister(value, registers),
							constructor, field));
				}
				if (output != null)
					defineValueArrayView(output, instructions, registers, registerTypes);
				appendDebugLocations(debugLocations, instructions.length - instructionStart, instruction.provenance);
				if (output != null && instructions.length > instructionStart) {
					var bindings = bindingsByValue.get(output.id);
					if (bindings != null) {
						var position = instructionStart;
						for (binding in bindings) {
							var key = binding.identity + "@" + position;
							if (!seenAssignments.exists(key)) {
								seenAssignments.set(key, true);
								debugAssignments.push({
									name: internString(binding.name),
									position: position,
									scopeEnd: -1
								});
								assignmentBindings.push(binding);
							}
						}
					}
				}
			}
			var terminator = block.terminator;
			if (terminator == null)
				throw new InternalError('Reachable IR block ${block.id} has no terminator');
			var terminatorStart = instructions.length;
			switch terminator.value {
				case Unreachable:
					// The fatal runtime native aborts the process and is not an exception, so no Haxe code can catch it. The block still needs an
					// ending the bytecode accepts: a throw of null that is never reached.
					instructions.push(HlInstruction.Call0(temporaryRegister(IrType.Void, registerTypes),
						requireFunction("__unreachable")));
					var neverThrown = temporaryRegister(IrType.Dyn, registerTypes);
					instructions.push(HlInstruction.LoadNull(neverThrown));
					instructions.push(HlInstruction.Throw(neverThrown));
				case Return(value):
					instructions.push(HlInstruction.Return(requireRegister(value, registers)));
				case Throw(value):
					instructions.push(HlInstruction.Throw(requireRegister(value, registers)));
				case Rethrow(value):
					instructions.push(HlInstruction.Rethrow(requireRegister(value, registers)));
				case Jump(target):
					var jumpMoves = edgeMoves(edges, block.id, target);
					if (jumpMoves != null)
						for (write in emitPhiMoves(jumpMoves, registers, registerTypes, instructions)) {
							var bindings = bindingsByValue.get(write.value.id);
							if (bindings != null)
								for (binding in bindings) {
									var assignmentKey = binding.identity + "@" + write.position;
									if (!seenAssignments.exists(assignmentKey)) {
										seenAssignments.set(assignmentKey, true);
										debugAssignments.push({
											name: internString(binding.name),
											position: write.position,
											scopeEnd: -1
										});
										assignmentBindings.push(binding);
									}
								}
						}
					if (target != fallsThroughTo)
						instructions.push(HlInstruction.Jump(target));
				case Branch(condition, yes, no):
					if (edgeMoves(edges, block.id, yes) != null || edgeMoves(edges, block.id, no) != null)
						throw new InternalError("Phi elimination requires split critical edges");
					if (yes == fallsThroughTo && no != fallsThroughTo)
						// The taken side is written next: jump to the other side on the complement, and fall through.
						instructions.push(fusedComparison != null ? complementJump(fusedComparison, no,
							fusedFloat) : HlInstruction.JumpFalse(requireRegister(condition, registers),
							no));
					else {
						if (fusedComparison != null)
							instructions.push(withJumpTarget(fusedComparison, yes));
						else
							instructions.push(HlInstruction.JumpTrue(requireRegister(condition, registers),
								yes));
						if (no != fallsThroughTo)
							instructions.push(HlInstruction.Jump(no));
					}
				case Switch(value, targets, otherwise):
					for (target in compiler.ir.IrSwitch.successors(targets, otherwise))
						if (edgeMoves(edges, block.id, target) != null)
							throw new InternalError("Phi elimination requires split critical edges");
					// HashLink's jump table takes only forward offsets: a target laid out before this block is reached through a
					// jump placed after the table. Values outside it fall through to the jump to `otherwise`.
					var stubs:Array<{label:Int, target:Int}> = [], entries:Array<Int> = [];
					for (target in targets)
						if (layoutPositions.get(target) > layoutIndex)
							entries.push(target);
						else {
							var stub = null;
							for (existing in stubs)
								if (existing.target == target)
									stub = existing.label;
							if (stub == null) {
								stub = freshLabel();
								stubs.push({label: stub, target: target});
							}
							entries.push(stub);
						}
					instructions.push(HlInstruction.Switch(requireRegister(value, registers), entries));
					if (otherwise != fallsThroughTo || stubs.length > 0)
						instructions.push(HlInstruction.Jump(otherwise));
					for (stub in stubs) {
						instructions.push(HlInstruction.Label(stub.label));
						instructions.push(HlInstruction.Jump(stub.target));
					}
			}
			appendDebugLocations(debugLocations, instructions.length - terminatorStart, terminator.provenance);
		}

		var scopedAssignments:Array<HlDebugAssignment> = [],
			lastScopeLocations:Map<String, Int> = [];
		for (index in 0...debugAssignments.length) {
			var assignment = debugAssignments[index],
				binding = assignmentBindings[index];
			scopedAssignments.push({
				name: assignment.name,
				position: assignment.position,
				scopeEnd: assignment.position < 0 ? -1 : scopeEndPosition(binding, debugLocations, assignment.position,
					instructions.length, lastScopeLocations)
			});
		}
		var key = view.typedInterfaceKey(fn.name);
		if (key != null) {
			var handleType = IrType.Abstract(HlTypedInterfaceTables.SLOT_TYPE),
				handle = temporaryRegister(handleType, registerTypes),
				keyRegister = temporaryRegister(IrType.TypeRef, registerTypes),
				receiver = temporaryRegister(IrType.Dyn, registerTypes),
				entry = temporaryRegister(IrType.Abstract(HlTypedInterfaceTables.ENTRY_TYPE), registerTypes),
				callable = temporaryRegister(IrType.Function([IrType.Dyn]
					.concat([for (i in 1...fn.arguments.length) fn.arguments[i].type]), fn.result),
					registerTypes),
				result = temporaryRegister(fn.result, registerTypes),
				global = internGlobalSlot("$typed-method-slot:" + key, handleType),
				fallback = freshLabel(),
				initialize = freshLabel(),
				ready = freshLabel();
			var fast:Array<HlInstruction> = [
				HlInstruction.GlobalGet(handle, global),
				HlInstruction.JumpNull(handle, initialize),
				HlInstruction.Jump(ready),
				HlInstruction.Label(initialize),
				HlInstruction.LoadType(keyRegister, internType(IrType.Abstract(key))),
				HlInstruction.Call1(handle, requireFunction(HlTypedInterfaceTables.SLOT_NATIVE), keyRegister),
				HlInstruction.GlobalSet(global, handle),
				HlInstruction.Label(ready),
				HlInstruction.ToDyn(receiver, 0),
				HlInstruction.Call2(entry, requireFunction(HlTypedInterfaceTables.ENTRY_NATIVE), receiver, handle),
				HlInstruction.JumpNull(entry, fallback),
				HlInstruction.UnsafeCast(callable, entry),
				HlInstruction.CallClosure(result, callable, [receiver].concat([for (i in 1...fn.arguments.length) i])),
				HlInstruction.Return(result),
				HlInstruction.Label(fallback)
			];
			var first = debugLocations.length == 0
				? debugLocation(SourceProvenance.generated("typed interface method table")) : debugLocations[0];
			debugLocations = [for (_ in fast) first].concat(debugLocations);
			instructions = fast.concat(instructions);
			for (i in 0...scopedAssignments.length) {
				var assignment = scopedAssignments[i];
				scopedAssignments[i] = {
					name: assignment.name,
					position: assignment.position < 0 ? assignment.position : assignment.position + fast.length,
					scopeEnd: assignment.scopeEnd < 0 ? assignment.scopeEnd : assignment.scopeEnd + fast.length
				};
			}
		}
		dropUnreferencedLabels(instructions, debugLocations, scopedAssignments);
		// Release code shares registers between values that are not live at once; development code keeps one per value, which is
		// what a debugger shows a variable from.
		if (!developmentMetadata)
			registerTypes = registerAllocation.run(instructions, registerTypes, fn.arguments.length);
		return new HlFunction(internFunctionType([for (argument in fn.arguments) argument.type], fn.result),
			requireFunction(fn.name), registerTypes,
			instructions.copy(), debugLocations.copy(), scopedAssignments);
	}

	/**
	 * Removes the labels no jump or trap names. HashLink needs a label only where control lands by a jump, and every label written is an
	 * instruction the VM compiles at load; a block reached by falling through needs none. Debug locations and the positions of
	 * debug assignments follow the instructions that stay.
	 */
	static function dropUnreferencedLabels(instructions:Array<HlInstruction>, debugLocations:Array<HlDebugLocation>,
			assignments:Array<HlDebugAssignment>):Void {
		var referenced:Map<Int, Bool> = [];
		for (instruction in instructions)
			switch instruction {
				case JumpSignedLessOrEqual(_, _, target), JumpSignedLess(_, _, target), JumpUnsignedLess(_, _, target),
					JumpNull(_, target), JumpEqual(_, _, target), JumpTrue(_, target), Jump(target), Trap(_, target, _),
					JumpFalse(_, target), JumpNotNull(_, target), JumpNotEqual(_, _, target), JumpNotLess(_, _, target),
					JumpNotGreaterOrEqual(_, _, target), JumpSignedGreaterOrEqual(_, _, target),
					JumpSignedGreater(_, _, target),
					JumpUnsignedGreaterOrEqual(_, _, target):
					referenced.set(target, true);
				case Switch(_, targets):
					for (target in targets)
						referenced.set(target, true);
				default:
			}
		var located = debugLocations.length == instructions.length, kept = 0, positions:Array<Int> = [];
		for (index in 0...instructions.length) {
			positions.push(kept);
			switch instructions[index] {
				case Label(id) if (!referenced.exists(id)):
				default:
					instructions[kept] = instructions[index];
					if (located)
						debugLocations[kept] = debugLocations[index];
					kept++;
			}
		}
		if (kept == instructions.length)
			return;
		positions.push(kept);
		instructions.resize(kept);
		if (located)
			debugLocations.resize(kept);
		for (index in 0...assignments.length) {
			var assignment = assignments[index];
			assignments[index] = {
				name: assignment.name,
				position: assignment.position < 0 ? assignment.position : positions[assignment.position],
				scopeEnd: assignment.scopeEnd < 0 ? assignment.scopeEnd : positions[assignment.scopeEnd]
			};
		}
	}

	function appendDebugLocations(output:Array<HlDebugLocation>, count:Int, provenance:SourceProvenance):Void
		for (_ in 0...count)
			output.push(debugLocation(provenance));

	static final generatedDebugLocation:HlDebugLocation = new HlDebugLocation("<generated>", 1, 1, 1, 1, 0, -1, -1, 1);

	// The last location made, and what it was made from: consecutive instructions mostly share their source.
	var lastProvenance:Null<SourceProvenance> = null;

	var lastSource:Null<compiler.ir.SourceProvenance.SourceLocation> = null;
	var lastFlags = -1;
	var lastLocation:Null<HlDebugLocation> = null;

	/** Locations are immutable, so opcodes from one provenance share a single one. */
	function debugLocation(provenance:SourceProvenance):HlDebugLocation {
		var last = lastLocation;
		if (last != null && provenance == lastProvenance)
			return last;
		var location = provenance.location;
		if (location == null)
			return generatedDebugLocation;
		var flags = switch provenance.origin {
			case CompilerGenerated(_): 1;
			case UserSource: 0;
		};
		if (last != null && location == lastSource && flags == lastFlags) {
			lastProvenance = provenance;
			return last;
		}
		var result = new HlDebugLocation(location.path, location.line, location.column, location.endLine,
			location.endColumn, location.sourceHash, location.start, location.end, flags);
		lastProvenance = provenance;
		lastSource = location;
		lastFlags = flags;
		lastLocation = result;
		return result;
	}

	/**
		The scope ends after the last location inside the binding's source range at or
		after `position`. That is the binding's overall last in-range location when
		it falls at or after `position`, so it is found once per scope, not once per
		assignment.
	**/
	static function scopeEndPosition(binding:compiler.ir.IrFunction.IrDebugBinding, locations:Array<HlDebugLocation>,
			position:Int, instructionCount:Int,
			lastByScope:Map<String, Int>):Int {
		var key = binding.identity + ":" + binding.scopeStart + ":" + binding.scopeEnd,
			cached = lastByScope.get(key),
			lastInScope:Int;
		if (cached == null) {
			lastInScope = -1;
			var index = locations.length - 1;
			while (index >= 0) {
				var location = locations[index];
				if (location.start >= 0
					&& location.start >= binding.scopeStart
					&& location.start < binding.scopeEnd
					&& location.path == binding.path) {
					lastInScope = index;
					break;
				}
				index--;
			}
			lastByScope.set(key, lastInScope);
		} else
			lastInScope = cached;
		var end = (lastInScope >= position ? lastInScope : position) + 1;
		return end >= instructionCount ? -1 : end;
	}

	static function blockProvenance(block:IrBlock):SourceProvenance {
		if (block.instructions.length > 0)
			return block.instructions[0].provenance;
		if (block.terminator != null)
			return block.terminator.provenance;
		return SourceProvenance.generated("empty-hl-block");
	}

	/**
		HashLink traps are lexical in the bytecode stream. CFG block identifiers are
		allocation details, so lay each protected region out before its handler and
		its continuation regardless of block creation order.
	**/
	static function orderedBlocks(fn:IrFunction):Array<IrBlock> {
		var byId:Map<Int, IrBlock> = [for (block in fn.blocks) block.id => block],
			seen:Map<Int, Bool> = [],
			output:Array<IrBlock> = [];
		appendReversePostorder(byId, seen, output, fn.blocks[0].id);
		for (block in fn.blocks)
			if (!seen.exists(block.id) && (block.instructions.length > 0 || block.terminator != null))
				appendReversePostorder(byId, seen, output, block.id);
		return output;
	}

	static function appendReversePostorder(byId:Map<Int, IrBlock>, seen:Map<Int, Bool>, output:Array<IrBlock>,
			entry:Int):Void {
		var postorder:Array<IrBlock> = [];
		visitPostorder(byId, seen, postorder, entry);
		var index = postorder.length;
		while (index > 0) {
			index--;
			output.push(postorder[index]);
		}
	}

	static function visitPostorder(byId:Map<Int, IrBlock>, seen:Map<Int, Bool>, output:Array<IrBlock>, id:Int):Void {
		if (seen.exists(id) || !byId.exists(id))
			return;
		var stack:Array<{id:Int, next:Int, children:Array<Int>}> = [];
		seen.set(id, true);
		stack.push({id: id, next: 0, children: postorderChildren(byId.get(id))});
		while (stack.length > 0) {
			var frame = stack[stack.length - 1];
			if (frame.next < frame.children.length) {
				var child = frame.children[frame.next++];
				if (seen.exists(child) || !byId.exists(child))
					continue;
				seen.set(child, true);
				stack.push({id: child, next: 0, children: postorderChildren(byId.get(child))});
			} else {
				output.push(byId.get(frame.id));
				stack.pop();
			}
		}
	}

	static function postorderChildren(block:IrBlock):Array<Int> {
		var region:Null<{catchBlock:Int, afterBlock:Int}> = null;
		for (instruction in block.instructions)
			switch instruction.value {
				case BeginTry(catchBlock, afterBlock, _):
					region = {catchBlock: catchBlock, afterBlock: afterBlock};
				default:
			}
		var children:Array<Int> = [];
		if (region != null) {
			// Visit structural exits first because reversal places the protected
			// body before its handler and the handler before the shared exit.
			children.push(region.afterBlock);
			children.push(region.catchBlock);
		}
		var terminator = block.terminator;
		if (terminator != null) {
			var successors:Array<Int> = switch terminator.value {
				case Jump(target): [target];
				case Branch(_, yes, no): [yes, no];
				case Switch(_, targets, otherwise): compiler.ir.IrSwitch.successors(targets, otherwise);
				case Return(_), Throw(_), Rethrow(_), Unreachable: [];
			};
			var successorIndex = successors.length;
			while (successorIndex > 0) {
				successorIndex--;
				children.push(successors[successorIndex]);
			}
		}
		return children;
	}

	/** The phi moves on the edge `from` to `to`, or null when it has none. */
	static function edgeMoves(edges:Map<Int, Map<Int, Array<{destination:IrValue, source:IrValue}>>>, from:Int,
			to:Int):Null<Array<{
				destination:IrValue,
				source:IrValue
			}>> {
		var targets = edges.get(from);
		return targets == null ? null : targets.get(to);
	}

	function emitPhiMoves(moves:Array<{destination:IrValue, source:IrValue}>, registers:Array<Int>,
			registerTypes:Array<Int>,
			instructions:Array<HlInstruction>):Array<{
				value:IrValue,
				position:Int
			}> {
		var writes:Array<{value:IrValue, position:Int}> = [];
		if (moves.length == 1) {
			var destination = requireRegister(moves[0].destination, registers),
				source = requireRegister(moves[0].source, registers);
			if (destination != source) {
				writes.push({value: moves[0].destination, position: instructions.length});
				instructions.push(HlInstruction.Move(destination, source));
			}
			return writes;
		}
		// The moves happen at once: a move is written once no move still to be written reads its destination, and a cycle of
		// moves is broken by saving one destination in a temporary and reading that instead.
		var pending:Array<{destination:Int, source:Int, value:IrValue}> = [];
		for (move in moves) {
			var destination = requireRegister(move.destination, registers),
				source = requireRegister(move.source, registers);
			if (destination != source)
				pending.push({destination: destination, source: source, value: move.destination});
		}
		while (pending.length > 0) {
			var ready = -1;
			for (index in 0...pending.length) {
				var read = false;
				for (other in pending)
					if (other.source == pending[index].destination) {
						read = true;
						break;
					}
				if (!read) {
					ready = index;
					break;
				}
			}
			if (ready < 0) {
				var saved = pending[0].destination,
					temporary = temporaryRegisterType(registerTypes[saved], registerTypes);
				instructions.push(HlInstruction.Move(temporary, saved));
				for (index in 0...pending.length)
					if (pending[index].source == saved)
						pending[index] = {
							destination: pending[index].destination,
							source: temporary,
							value: pending[index].value
						};
				continue;
			}
			var move = pending.splice(ready, 1)[0];
			writes.push({value: move.value, position: instructions.length});
			instructions.push(HlInstruction.Move(move.destination, move.source));
		}
		return writes;
	}

	/** The jump taken when a comparison holds; `target` may be filled in later with `withJumpTarget`. */
	static function comparisonJump(operation:Int, leftNull:Bool, rightNull:Bool, leftReg:Int, rightReg:Int,
			target:Int):HlInstruction {
		var label = target;
		if (operation == 2 && (leftNull || rightNull))
			return HlInstruction.JumpNull(leftNull ? rightReg : leftReg, label);
		return switch operation {
			case 0: HlInstruction.JumpSignedLess(leftReg, rightReg, label);
			case 1: HlInstruction.JumpSignedLessOrEqual(leftReg, rightReg, label);
			default: HlInstruction.JumpEqual(leftReg, rightReg, label);
		};
	}

	/**
	 * The jump taken exactly when the comparison `jump` is not, to `target`. Floats (`float`) use the VM's "not" jumps, taken on NaN too;
	 * the VM compares those as floats only, so integers use the signed complements.
	 */
	static function complementJump(jump:HlInstruction, target:Int, float:Bool):HlInstruction
		return switch jump {
			case JumpSignedLess(left, right, _): float ? HlInstruction.JumpNotLess(left, right,
				target) : HlInstruction.JumpSignedGreaterOrEqual(left, right, target);
			// !(left <= right) is !(right >= left), and for integers left > right
			case JumpSignedLessOrEqual(left, right, _): float ? HlInstruction.JumpNotGreaterOrEqual(right, left,
				target) : HlInstruction.JumpSignedGreater(left, right, target);
			case JumpNull(value, _): HlInstruction.JumpNotNull(value, target);
			case JumpEqual(left, right, _): HlInstruction.JumpNotEqual(left, right, target);
			default: throw new InternalError("Not a comparison jump");
		};

	static function isArray(type:IrType):Bool
		return switch type {
			case Array(_): true;
			default: false;
		};

	static function isFloat(type:IrType):Bool
		return switch type {
			case F32 | F64: true;
			default: false;
		};

	static function withJumpTarget(jump:HlInstruction, target:Int):HlInstruction
		return switch jump {
			case JumpSignedLess(left, right, _): HlInstruction.JumpSignedLess(left, right, target);
			case JumpSignedLessOrEqual(left, right, _): HlInstruction.JumpSignedLessOrEqual(left, right, target);
			case JumpNull(value, _): HlInstruction.JumpNull(value, target);
			case JumpEqual(left, right, _): HlInstruction.JumpEqual(left, right, target);
			default: throw new InternalError("Not a comparison jump");
		};

	function lowerComparison(output:IrValue, left:IrValue, right:IrValue, operation:Int, leftNull:Bool, rightNull:Bool,
			registers:Array<Int>,
			registerTypes:Array<Int>, instructions:Array<HlInstruction>):Void {
		var destination = defineRegister(output, registers, registerTypes);
		var leftReg = requireRegister(left, registers),
			rightReg = requireRegister(right, registers);
		var trueLabel = freshLabel(),
			endLabel = freshLabel();
		instructions.push(comparisonJump(operation, leftNull, rightNull, leftReg, rightReg, trueLabel));
		instructions.push(HlInstruction.LoadBool(destination, false));
		instructions.push(HlInstruction.Jump(endLabel));
		instructions.push(HlInstruction.Label(trueLabel));
		instructions.push(HlInstruction.LoadBool(destination, true));
		instructions.push(HlInstruction.Label(endLabel));
	}

	/** A label of the function being lowered that no block has: block `b` is label `b`. */
	function freshLabel():Int
		return nextLabel++;

	function defineRegister(value:IrValue, registers:Array<Int>, types:Array<Int>):Int {
		if (value.id < registers.length && registers[value.id] >= 0)
			return registers[value.id];
		var index = types.length;
		while (registers.length <= value.id)
			registers.push(-1);
		registers[value.id] = index;
		types.push(internType(value.type));
		return index;
	}

	/**
	 * A HashLink String is an object carrying its UTF-16 data and length. A literal reads a global holding one String
	 * created when the module loads, or, for a literal a patch introduces, when the patch is applied; evaluating it
	 * allocates nothing.
	 */
	function lowerStringLiteral(destination:Int, value:String, registerTypes:Array<Int>,
			instructions:Array<HlInstruction>):Void
		instructions.push(HlInstruction.GlobalGet(destination, internStringLiteral(value)));

	/**
	 * A constructor without fields denotes one value, so it is made the first time it is evaluated and kept in a global;
	 * every later evaluation is a global load. Making it on first use needs no initialization order, and a global a patch
	 * adds simply starts out null.
	 */
	function lowerEnumConstant(destination:Int, typeName:String, constructor:Int,
			instructions:Array<HlInstruction>):Void {
		var global = internEnumValue(typeName, constructor),
			make = freshLabel(),
			done = freshLabel();
		instructions.push(HlInstruction.GlobalGet(destination, global));
		instructions.push(HlInstruction.JumpNull(destination, make));
		instructions.push(HlInstruction.Jump(done));
		instructions.push(HlInstruction.Label(make));
		instructions.push(HlInstruction.MakeEnum(destination, constructor, []));
		instructions.push(HlInstruction.GlobalSet(global, destination));
		instructions.push(HlInstruction.Label(done));
	}

	/** Array and index pairs, as `arrayId:indexId`, already known to be in range at this point of the block being lowered. */
	final provenInRange:Map<String, Bool> = [];

	/** Historical validation within this block, preserving compound-write semantics after a callee shrinks an array. */
	final validatedArrayAccesses:Map<String, Bool> = [];

	/**
	 * The byte-offset register of every array and index pair accessed so far in the block being lowered. The offset
	 * depends only on the index, so it stays valid however much code runs in between. Read validation is recorded
	 * separately, since fused reads no longer need an offset register.
	 */
	final elementOffsets:Map<String, Int> = [];

	/** The value array each array value's header leads to, resolved in the block being lowered (`valueArrayView`). */
	final valueArrayViews:Map<Int, ValueArrayView> = [];

	/** The array values of the function being lowered that have inline reads, and their views resolved where defined. */
	final viewedArrays:Map<Int, Bool> = [];

	final definedViews:Map<Int, ValueArrayView> = [];

	var hasViewedArrays = false;

	/** The function being lowered, and the proofs of its loops' array indices, made when a read first asks for one. */
	var loweringFunction:Null<IrFunction> = null;

	var loopBounds:Null<compiler.ir.IrLoopBounds> = null;

	@:processWide("an empty set of calls known not to resize arrays, never added to")
	static final noPureCalls:Map<String, Bool> = [];

	/** Whether the loops around `block` prove `index` in range of `array` (`IrLoopBounds`). */
	function provenByLoop(array:IrValue, index:IrValue, block:Int):Bool {
		var bounds = loopBounds, fn = loweringFunction;
		if (fn == null)
			return false;
		if (bounds == null) {
			bounds = new compiler.ir.IrLoopBounds(fn, noPureCalls);
			loopBounds = bounds;
		}
		return bounds.proven(array, index, block);
	}

	/**
	 * Whether an instruction leaves every proven array bound intact: it runs no code and shrinks no array. Anything else,
	 * including every call, forgets them. Array writes only ever grow an array, so they keep them.
	 */
	static function keepsArrayBounds(instruction:IrInstruction):Bool
		return switch instruction {
			case ConstVoid(_), ConstInt(_, _), ConstFloat(_, _), ConstString(_, _), ConstBool(_, _), ConstNull(_),
				TypeValue(_, _), ToDyn(_, _),
				IntToFloat(_, _), IntToInt64(_, _), FloatToInt(_, _), FloatToFloat(_, _), Add(_, _, _), Sub(_, _, _),
				Mul(_, _, _), BitAnd(_, _, _),
				BitXor(_, _, _), BitOr(_, _, _), ShiftLeft(_, _, _), ShiftRight(_, _, _), UnsignedShiftRight(_, _, _),
				Less(_, _, _), LessEqual(_, _, _),
				Equal(_, _, _), FieldGet(_, _, _), ArrayGet(_, _, _), ArraySet(_, _, _), ArraySize(_, _),
				Phi(_, _): true;
			default: false;
		};

	/**
	 * An Int or Float array write with the bounds test in the bytecode. Reads use OGetArray, whose x86-64 JIT
	 * fuses its check and address calculation. Writes retain growth semantics: an index in range (one unsigned
	 * test against the size, which also rejects a negative index) goes straight to the element, and only an
	 * out-of-range index calls `operation` (`array_check` raises, `array_ensure` grows the array or raises for a
	 * negative index).
	 *
	 * An access to a pair already proven in range with nothing but arithmetic in between skips the test. A *write*
	 * to a pair an earlier access in the block validated also skips it across calls, so `a[i] += f(x)` tests once,
	 * as Haxe does. That is memory safe because an array's capacity only ever grows: the index stays inside the
	 * allocation, and the data pointer is reloaded for every access so a callee that grew the array cannot leave
	 * the write in a stale buffer. It differs from a re-test only when the callee shrank the array below the index,
	 * where the write lands past the logical end instead of extending the array. Reads always re-test after a call,
	 * so reading a removed element still raises.
	 */
	function lowerRawArrayAccess(array:IrValue, index:IrValue, operation:String, writes:Bool,
			instructions:Array<HlInstruction>, registers:Array<Int>,
			registerTypes:Array<Int>, access:(Int, Int) -> HlInstruction):Void {
		var elementShift = rawArrayShift(array.type);
		if (elementShift == null)
			throw new InternalError("Inline array access requires an Int or Float array");
		var arrayRegister = requireRegister(array, registers),
			indexRegister = requireRegister(index, registers),
			key = '${array.id}:${index.id}';
		if (!provenInRange.exists(key) && !(writes && validatedArrayAccesses.exists(key))) {
			var outOfRange = freshLabel(),
				inRange = freshLabel(),
				size = temporaryRegister(IrType.I32, registerTypes),
				unused = temporaryRegister(IrType.Void, registerTypes);
			instructions.push(HlInstruction.ArraySize(size, arrayRegister));
			instructions.push(HlInstruction.JumpUnsignedLess(indexRegister, size, inRange));
			instructions.push(HlInstruction.Label(outOfRange));
			instructions.push(HlInstruction.Call2(unused, requireFunction(rawArrayNativeName(array.type, operation)),
				arrayRegister, indexRegister));
			instructions.push(HlInstruction.Label(inRange));
			provenInRange.set(key, true);
		}
		validatedArrayAccesses.set(key, true);
		var offset = elementOffsets.get(key);
		if (offset == null) {
			var shift = temporaryRegister(IrType.I32, registerTypes);
			offset = temporaryRegister(IrType.I32, registerTypes);
			instructions.push(HlInstruction.LoadInt(shift, internInt(elementShift)));
			instructions.push(HlInstruction.ShiftLeft(offset, indexRegister, shift));
			elementOffsets.set(key, offset);
		}
		var data = temporaryRegister(IrType.Bytes, registerTypes);
		instructions.push(HlInstruction.RefData(data, arrayRegister));
		instructions.push(access(data, offset));
	}

	/** Inline the common case; the existing native keeps allocation and error behavior on slow paths. */
	/** The two references a reference-identity test compares, as raw pointers: a virtual is compared by the object it wraps. */
	function identityPointers(arguments:Array<IrValue>, instructions:Array<HlInstruction>, registers:Array<Int>,
			registerTypes:Array<Int>):Array<Int> {
		var pointers:Array<Int> = [];
		for (arg in arguments) {
			var source = requireRegister(arg, registers);
			switch arg.type {
				case Virtual(_):
					var concrete = temporaryRegister(IrType.Dyn, registerTypes);
					instructions.push(HlInstruction.ToDyn(concrete, source));
					source = concrete;
				default:
			}
			var pointer = temporaryRegister(IrType.RawPtr, registerTypes);
			instructions.push(HlInstruction.UnsafeCast(pointer, source));
			pointers.push(pointer);
		}
		return pointers;
	}

	function lowerRuntimeFastPath(output:IrValue, name:String, arguments:Array<IrValue>,
			instructions:Array<HlInstruction>, registers:Array<Int>,
			registerTypes:Array<Int>):Bool {
		if (compiler.ir.IrScalarWordBits.matches(name)) {
			if (arguments.length != 1 || !compiler.ir.IrScalarWordBits.valid(name, arguments[0].type, output.type))
				throw new InternalError("Invalid scalar word transport signature");
			var scalar = name == compiler.ir.IrScalarWordBits.PACK ? arguments[0].type : output.type;
			if (compiler.ir.IrVerifier.sameType(scalar, IrType.Abstract("native_callback")))
				throw new InternalError("HashLink callbacks belong in the reference lane");
			instructions.push(HlInstruction.UnsafeCast(defineRegister(output, registers, registerTypes),
				requireRegister(arguments[0], registers)));
			return true;
		}
		if (name == compiler.ir.IrValueLaneReference.PACK || name == compiler.ir.IrValueLaneReference.UNPACK) {
			instructions.push(HlInstruction.UnsafeCast(defineRegister(output, registers, registerTypes),
				requireRegister(arguments[0], registers)));
			return true;
		}
		if (name == compiler.ir.IrExactTypeFacts.TEST) {
			// A plain object of exactly the class: its type pointer equals the class's. Null reads as `void`, a virtual as its own
			// virtual type and a boxed value as its scalar type, so none of them matches an object class.
			var actual = temporaryRegister(IrType.TypeRef, registerTypes),
				result = defineRegister(output, registers, registerTypes),
				yes = freshLabel(),
				done = freshLabel();
			instructions.push(HlInstruction.GetType(actual, requireRegister(arguments[0], registers)));
			instructions.push(HlInstruction.JumpEqual(actual, requireRegister(arguments[1], registers), yes));
			instructions.push(HlInstruction.LoadBool(result, false));
			instructions.push(HlInstruction.Jump(done));
			instructions.push(HlInstruction.Label(yes));
			instructions.push(HlInstruction.LoadBool(result, true));
			instructions.push(HlInstruction.Label(done));
			return true;
		}
		if (name == compiler.ir.IrReferenceIdentity.NAME) {
			var pointers = identityPointers(arguments, instructions, registers, registerTypes);
			var result = defineRegister(output, registers, registerTypes),
				yes = freshLabel(),
				done = freshLabel();
			instructions.push(HlInstruction.JumpEqual(pointers[0], pointers[1], yes));
			instructions.push(HlInstruction.LoadBool(result, false));
			instructions.push(HlInstruction.Jump(done));
			instructions.push(HlInstruction.Label(yes));
			instructions.push(HlInstruction.LoadBool(result, true));
			instructions.push(HlInstruction.Label(done));
			return true;
		}
		if (name == compiler.ir.IrReceiverCheck.NAME) {
			instructions.push(HlInstruction.NullCheck(requireRegister(arguments[0], registers)));
			return true;
		}
		if (name == compiler.ir.IrHlScalarRef.ADDRESS) {
			instructions.push(HlInstruction.Ref(defineRegister(output, registers, registerTypes),
				requireRegister(arguments[0], registers)));
			return true;
		}
		if (name == compiler.ir.IrHlScalarRef.LOAD) {
			instructions.push(HlInstruction.Unref(defineRegister(output, registers, registerTypes),
				requireRegister(arguments[0], registers)));
			return true;
		}
		if (name == compiler.ir.IrHlScalarRef.STORE) {
			instructions.push(HlInstruction.Setref(requireRegister(arguments[0], registers),
				requireRegister(arguments[1], registers)));
			return true;
		}
		var push = name == "__array_push_i32" || name == "__array_push_i64" || name == "__array_push_f64"
			|| name == "__array_push_bool"
			|| name == "__array_push_bytes" || name == "__array_push_ref";
		var get = name == "__bytes_get", set = name == "__bytes_set";
		if (!push && !get && !set)
			return false;
		var destination = defineRegister(output, registers, registerTypes);
		var args = [for (argument in arguments) requireRegister(argument, registers)];
		var slow = freshLabel(),
			done = freshLabel();
		var size = temporaryRegister(IrType.I32, registerTypes);
		instructions.push(HlInstruction.JumpNull(args[0], slow));
		// The header is read through an object type laid out like it: one field access per header field. The fast path falls
		// through; the slow path is the native, which keeps allocation and error behavior.
		var header = temporaryRegisterType(internRuntimeHeader(push ? ArrayHeader : BytesHeader), registerTypes);
		instructions.push(HlInstruction.UnsafeCast(header, args[0]));
		if (push) {
			var capacity = temporaryRegister(IrType.I32, registerTypes);
			var one = temporaryRegister(IrType.I32, registerTypes);
			instructions.push(HlInstruction.FieldGet(size, header, 1));
			instructions.push(HlInstruction.FieldGet(capacity, header, 2));
			instructions.push(HlInstruction.JumpUnsignedGreaterOrEqual(size, capacity, slow));
			instructions.push(HlInstruction.LoadInt(one, internInt(1)));
			instructions.push(HlInstruction.Add(destination, size, one));
			instructions.push(HlInstruction.FieldSet(header, 1, destination));
			// OSetref performs the managed store/write barrier without OSetArray's native bounds helper.
			var data = temporaryRegister(IrType.RawPtr, registerTypes);
			var slot = temporaryRegisterType(internReference(arguments[1].type), registerTypes);
			instructions.push(HlInstruction.RefData(data, args[0]));
			instructions.push(HlInstruction.UnsafeCast(slot, data));
			instructions.push(HlInstruction.RefOffset(slot, slot, size));
			instructions.push(HlInstruction.Setref(slot, args[1]));
		} else {
			var data = temporaryRegister(IrType.RawPtr, registerTypes);
			instructions.push(HlInstruction.FieldGet(size, header, 1));
			instructions.push(HlInstruction.JumpUnsignedGreaterOrEqual(args[1], size, slow));
			instructions.push(HlInstruction.FieldGet(data, header, 0));
			instructions.push(get ? HlInstruction.GetI8(destination, data, args[1]) : HlInstruction.SetI8(data, args[1],
				args[2]));
		}
		instructions.push(HlInstruction.Jump(done));
		instructions.push(HlInstruction.Label(slow));
		if (args.length == 2)
			instructions.push(HlInstruction.Call2(destination, requireFunction(name), args[0], args[1]));
		else
			instructions.push(HlInstruction.CallN(destination, requireFunction(name), args));
		instructions.push(HlInstruction.Label(done));
		return true;
	}

	function temporaryRegister(type:IrType, types:Array<Int>):Int {
		var index = types.length;
		types.push(internType(type));
		return index;
	}

	function temporaryRegisterType(type:Int, types:Array<Int>):Int {
		var index = types.length;
		types.push(type);
		return index;
	}

	static function unsupportedCDispatchArgument(type:IrType):Bool
		return switch type {
			case I32, I64, IrType.Bool, F32, F64, IrType.Bytes, IrType.RawPtr, IrType.ManagedBytes,
				IrType.Abstract("realtime_bytes"),
				IrType.Abstract("native_pointer"), IrType.Abstract("native_callback"): false;
			default: true;
		};

	static function unsupportedCDispatchResult(type:IrType):Bool
		return switch type {
			case I32, I64, IrType.Bool, F32, F64, IrType.Bytes, IrType.RawPtr, IrType.ManagedBytes,
				IrType.Abstract("native_pointer"),
				IrType.Abstract("realtime_bytes"): false;
			default: true;
		};

	static function isNativePointer(type:IrType):Bool
		return switch type {
			case IrType.Abstract("native_pointer"): true;
			case _: false;
		};

	static function isManagedPointerBytes(native:IrCNative):Bool
		return native.pointerLength != null && switch native.result {
			case IrType.ManagedBytes, IrType.Abstract("realtime_bytes"): true;
			case _: false;
		};

	static function instructionOutput(instruction:IrInstruction):Null<IrValue>
		return compiler.ir.IrOperands.output(instruction);

	function requireRegister(value:IrValue, registers:Array<Int>):Int {
		var register = value.id >= 0 && value.id < registers.length ? registers[value.id] : -1;
		if (register < 0)
			throw new InternalError('IR value ${value.id} is used before definition');
		return register;
	}

	static function isAggregateResult(native:IrCNative):Bool
		return native.pointerLength == null && switch (native.result) {
			case IrType.ManagedBytes, IrType.Abstract("realtime_bytes"): true;
			case _: false;
		};

	static function isUtf8Result(native:IrCNative):Bool {
		var separator = native.signature.indexOf(">");
		if (separator < 0)
			return false;
		var result = native.signature.substr(separator + 1);
		return StringTools.startsWith(result, "13") || StringTools.startsWith(result, "14");
	}

	// Everything below that asks the symbol tables or the function layout for an index also notes the question and the answer, when
	// the function being lowered is recorded: those requests are what lets another build give the function other indices.
	function internInt(value:Int):Int {
		var index = symbols.internInt(value);
		if (requests != null)
			requests.push(ConstInt(value, index));
		return index;
	}

	function internFloat(value:Float):Int {
		var index = symbols.internFloat(value);
		if (requests != null)
			requests.push(ConstFloat(value, index));
		return index;
	}

	function internString(value:String):Int {
		var index = symbols.internString(value);
		if (requests != null)
			requests.push(ConstString(value, index));
		return index;
	}

	function internType(type:IrType):Int {
		var index = HlRemap.typeIndex(symbols, type);
		if (requests != null)
			requests.push(TypeOf(type, index));
		return index;
	}

	function internFunctionType(arguments:Array<IrType>, result:IrType):Int
		return internType(IrType.Function(arguments, result));

	function internReference(type:IrType):Int {
		var index = symbols.internReference(type);
		if (requests != null)
			requests.push(RefTo(type, index));
		return index;
	}

	/** An object type laid out like the runtime header `kind` (`HlSymbolTable.internRuntimeHeader`). */
	function internRuntimeHeader(kind:HlRuntimeHeader):Int {
		var index = symbols.internRuntimeHeader(kind);
		if (requests != null)
			requests.push(RuntimeHeader(kind, index));
		return index;
	}

	function internNativeStorage(type:IrType, layout:Null<compiler.ir.Ir.IrScalarStorage>):Null<Int> {
		var index = symbols.internNativeFieldStorageType(type, layout);
		if (requests != null && layout != null)
			requests.push(NativeStorage(type, layout, index));
		return index;
	}

	function internGlobalSlot(name:String, type:IrType):Int {
		var index = symbols.internGlobal(name, type);
		if (requests != null)
			requests.push(GlobalSlot(name, type, index));
		return index;
	}

	function requireGlobal(name:String):Int {
		var index = symbols.requireGlobalIndex(name);
		if (requests != null)
			requests.push(GlobalByName(name, index));
		return index;
	}

	function internStringLiteral(value:String):Int {
		var index = symbols.internStringConstant(value);
		if (requests != null)
			requests.push(StringLiteral(value, index));
		return index;
	}

	function internEnumValue(enumName:String, constructor:Int):Int {
		var index = symbols.internEnumConstant(enumName, constructor);
		if (requests != null)
			requests.push(EnumValue(enumName, constructor, index));
		return index;
	}

	/**
	 * The type index of object `name`. An object the program no longer has can still be named by a function the module keeps
	 * for the running program's closures (`HlModuleAssembler.dropGuards`), such as a lambda an edit deleted or whose captures
	 * changed, with its environment. A resident session reuses that function's lowered code, but a resumed one lowers it again
	 * from its IR, so such an object resolves to the type the running module has (`publishedObjectType`).
	 */
	function requireObjectType(name:String):Int {
		var index = objectTypeIndices.get(name);
		if (index == null)
			index = publishedObjectType(name);
		if (index == null)
			throw new HlMissingEntity('Unknown IR object "$name"');
		if (requests != null)
			requests.push(TypeOf(IrType.Obj(name), index));
		return index;
	}

	/** The published type index of object `name` when the program does not declare it, else null (see `requireObjectType`). */
	function publishedObjectType(name:String):Null<Int> {
		if (view.object(name) != null)
			return null;
		var published = symbols.objectDefinition(name);
		return published == null ? null : published.index;
	}

	/** HashLink's index of field `name` in published object `typeName`, declared by it or one of its published bases. */
	function publishedFieldIndex(typeName:String, name:String):Null<{index:Int, owner:String}> {
		var owner:Null<String> = typeName;
		while (owner != null) {
			var index = symbols.objectFieldIndex(owner, name),
				published = symbols.objectDefinition(owner);
			if (index != null)
				return {index: index, owner: owner};
			owner = published == null ? null : switch published.definition {
				case Object(_, base, _, _, _, _) if (base >= 0):
					switch symbols.types[base] {
						case Object(baseName, _, _, _, _, _): symbols.strings[baseName];
						default: null;
					}
				default: null;
			};
		}
		return null;
	}

	function requireEnumConstructor(typeName:String, type:IrType, constructor:Int):Int {
		var name = switch type {
			case Enum(value): value;
			default: throw new InternalError('IR value is not an enum');
		};
		if (name != typeName)
			throw new InternalError('IR enum constructor type mismatch');
		if (!enumTypeIndices.exists(name))
			throw new InternalError('Unknown IR enum "$name"');
		if (constructor < 0)
			throw new InternalError('Invalid IR enum constructor $constructor');
		return constructor;
	}

	function requireObjectField(object:IrValue, name:String):Int {
		var typeName = switch object.type {
			case Obj(value): value;
			default: throw new InternalError('IR value ${object.id} is not an object');
		};
		return requireObjectFieldByType(typeName, name);
	}

	/**
	 * The field's index in the type this build publishes. A live patch keeps every field where the running module has it,
	 * moves none, and gives added ones reserved slots, so the index comes from the type, not from the field's position in
	 * the IR: the IR declares the field's owner, the type its slot.
	 */
	function requireObjectFieldByType(typeName:String, name:String):Int {
		var byName = fieldSlots.get(typeName),
			cached = byName == null ? null : byName.get(name);
		if (cached != null) {
			if (requests != null)
				requests.push(FieldSlot(cached.owner, name, cached.index));
			return cached.index;
		}
		var owner = typeName;
		while (true) {
			var descriptor = view.object(owner);
			if (descriptor == null) {
				// An object only a function the program no longer has names: its fields are where the running module has them.
				var published:Null<{index:Int, owner:String}> = null;
				if (owner == typeName && publishedObjectType(typeName) != null)
					published = publishedFieldIndex(typeName, name);
				if (published != null) {
					if (byName == null) {
						byName = [];
						fieldSlots.set(typeName, byName);
					}
					byName.set(name, published);
					if (requests != null)
						requests.push(FieldSlot(published.owner, name, published.index));
					return published.index;
				}
				throw new HlMissingEntity('Unknown IR object "$owner"');
			}
			var declares = false;
			for (field in descriptor.fields)
				if (field.name == name)
					declares = true;
			if (declares)
				break;
			if (descriptor.base == null)
				throw new HlMissingEntity('Unknown IR field "$typeName.$name"');
			owner = Std.string(descriptor.base);
		}
		var index = symbols.objectFieldIndex(owner, name);
		if (index == null)
			throw new InternalError('IR field "$owner.$name" has no slot in its HashLink type');
		var resolved:Int = index;
		if (byName == null) {
			byName = [];
			fieldSlots.set(typeName, byName);
		}
		byName.set(name, {index: resolved, owner: owner});
		if (requests != null)
			requests.push(FieldSlot(owner, name, resolved));
		return resolved;
	}

	/**
	 * A live build reserves slots in every object a patch can add fields to: not value objects, which other objects hold
	 * inline, not objects natives lay out, and not closure environments, whose captures a patch cannot change.
	 */
	function reservedSlots(object:IrObject):Int {
		if (fieldReserve <= 0
			|| object.isValue
			|| object.nativeLayout != null
			|| StringTools.startsWith(object.name, compiler.semantic.LambdaName.ENVIRONMENT_PREFIX)
			|| nativeVisible.exists(object.name))
			return 0;
		for (field in object.fields)
			if (field.nativeLayout != null)
				return 0;
		return fieldReserve;
	}

	/**
	 * The objects a native's arguments or result reach. HashLink checks a native's signature when it loads a module, and
	 * the signature spells out every field of an object it reaches, through bases, fields, nullables and functions
	 * (`append_type` in module.c), so reserved slots there would not match the library's declared signature.
	 */
	public static function nativeVisibleObjects(objects:Array<IrObject>,
			natives:Array<Array<IrNative>>):Map<String, Bool> {
		var byName:Map<String, IrObject> = [],
			visible:Map<String, Bool> = [],
			pending:Array<IrType> = [];
		for (object in objects)
			byName.set(object.name, object);
		for (group in natives)
			for (native in group) {
				for (argument in native.arguments)
					pending.push(argument);
				pending.push(native.result);
			}
		while (pending.length > 0) {
			var type = pending.pop();
			switch type {
				case Obj(name):
					var object = byName.get(name);
					while (object != null && !visible.exists(object.name)) {
						visible.set(object.name, true);
						for (field in object.fields)
							pending.push(field.type);
						object = object.base == null ? null : byName.get(Std.string(object.base));
					}
				case Nullable(element):
					pending.push(element);
				case Function(arguments, result):
					for (argument in arguments)
						pending.push(argument);
					pending.push(result);
				default:
			}
		}
		return visible;
	}

	function objectFieldNativeLayout(object:IrValue, name:String):Null<compiler.ir.Ir.IrScalarStorage> {
		var typeName = switch object.type {
			case Obj(value): value;
			default: return null;
		};
		return objectFieldNativeLayoutForType(typeName, name);
	}

	function objectFieldNativeLayoutForType(typeName:String, name:String):Null<compiler.ir.Ir.IrScalarStorage> {
		var descriptor = view.object(typeName);
		if (descriptor == null)
			return null;
		for (field in descriptor.fields)
			if (field.name == name)
				return compiler.ir.IrFieldStorage.scalar(field);
		return descriptor.base == null ? null : objectFieldNativeLayoutForType(Std.string(descriptor.base), name);
	}

	/** The implementing function of `name` when `value` is an instance of a value class, whose methods are not virtual. */
	function valueMethodFunction(value:IrValue, name:String):Null<String> {
		var typeName = switch value.type {
			case Obj(objectName): objectName;
			default: return null;
		};
		var descriptor = view.object(typeName);
		if (descriptor == null || !descriptor.isValue)
			return null;
		for (method in descriptor.methods)
			if (method.name == name)
				return method.functionName.name;
		return null;
	}

	/**
	 * The implementing function of `name` on `value`'s object type when the published prototype has no slot for it: a
	 * method a live patch added. The patch planner lets one in only when nothing overrides it and it overrides nothing, so
	 * a direct call reaches the method every receiver has.
	 */
	function addedMethodFunction(value:IrValue, name:String):Null<String> {
		var typeName = switch value.type {
			case Obj(objectName): objectName;
			default: return null;
		};
		var slots = symbols.objectMethodSlots(typeName);
		if (requests != null)
			requests.push(MethodSlotKnown(typeName, name, HlRemap.methodSlotAnswer(symbols, typeName, name)));
		if (slots == null || slots.exists(name))
			return null;
		var owner:Null<String> = typeName;
		while (owner != null) {
			var descriptor = view.object(owner);
			if (descriptor == null)
				return null;
			for (method in descriptor.methods)
				if (method.name == name)
					return method.functionName.name;
			owner = descriptor.base == null ? null : Std.string(descriptor.base);
		}
		return null;
	}

	function requireObjectMethod(value:IrValue, name:String):Int {
		var typeName = switch value.type {
			case Obj(value): value;
			case Virtual(value):
				var slot = symbols.requireInterfaceMethodIndex(value, name);
				if (requests != null)
					requests.push(InterfaceSlot(value, name, slot));
				return slot;
			default: throw new InternalError('IR value ${value.id} is not an object');
		};
		var slot = symbols.requireObjectMethodIndex(typeName, name);
		if (requests != null)
			requests.push(MethodSlot(typeName, name, slot));
		return slot;
	}

	/** Every interface `object` implements, directly or through interface bases, that its base class does not already provide.
	 * HashLink caches the virtual built for an interface conversion in an unnamed object field of that interface's type;
	 * without one `ToVirtual` allocates a new virtual on every conversion.
	 */
	function interfaceSlotsFor(object:IrObject):Array<String> {
		var inherited:Map<String, Bool> = [];
		var baseName = object.base == null ? "" : Std.string(object.base);
		while (baseName.length > 0 && view.hasObject(baseName)) {
			var base = view.object(baseName);
			if (base == null)
				break;
			for (name in closeInterfaces(base.interfaces))
				inherited.set(name, true);
			baseName = base.base == null ? "" : Std.string(base.base);
		}
		return [
			for (name in closeInterfaces(object.interfaces))
				// These interfaces describe compiler-selected value operations. Their calls are statically lowered, so
				// caching an HL virtual on each instance only bloats objects and inline structs without serving dispatch.
				if (!inherited.exists(name) && !isValueCapability(name)) name
		];
	}

	static function isValueCapability(name:String):Bool
		return name == "Equatable" || name == "Hashable" || name == "Diffable";

	function closeInterfaces(names:Array<String>):Array<String> {
		var result:Array<String> = [], seen:Map<String, Bool> = [];
		function visit(name:String):Void {
			if (seen.exists(name))
				return;
			seen.set(name, true);
			result.push(name);
			if (interfaceBases.exists(name))
				for (base in interfaceBases.get(name))
					visit(base);
		}
		for (name in names)
			visit(name);
		return result;
	}

	function addFunctionName(name:String, index:Int):Void {
		if (functionIndices.exists(name))
			throw new InternalError('Duplicate IR function "$name"');
		functionIndices.set(name, index);
	}

	function requireFunction(name:String):Int {
		if (!functionIndices.exists(name))
			throw new InternalError('Unknown IR function "$name"');
		var index = functionIndices.get(name);
		if (requests != null)
			requests.push(FunctionRef(name, index));
		return index;
	}
}

/** A value array scalar slot read inline: its bit offset in the element, its width in bits and whether it is signed. */
private typedef InlineValueSlot = {
	final offset:Int;
	final width:Int;
	final signed:Bool;
}

/** A value array as raw memory (null for a header that is no value array's) and its stride in bytes. */
private typedef ValueArrayView = {
	final array:Int;
	final strideBytes:Int;
}
