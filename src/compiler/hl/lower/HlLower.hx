package compiler.hl.lower;

import compiler.core.PeakProbe;
import compiler.core.InternalError;
import compiler.hl.incremental.HlSymbolRequest.HlRuntimeHeader;
import compiler.hl.lower.HlLoweringDecisions.HlCallKind;
import compiler.hl.lower.HlLoweringDecisions.InlineValueSlot;
import compiler.ir.model.IrTypeIdentity;
import compiler.ir.model.IrBody;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrTypeIds;
import compiler.ir.model.IrValueId;
import compiler.hl.HlCode;
import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.HlFunction;
import compiler.hl.HlFunction.HlInstruction;
import compiler.hl.HlFunction.HlDebugLocation;
import compiler.hl.HlCode.HlDebugSection;
import compiler.hl.HlFunction.HlDebugAssignment;
import compiler.hl.HlLz4;
import compiler.hl.HlType;
import compiler.hl.HlWriter;
import compiler.hl.incremental.HlSymbolTable;
import compiler.ir.model.Ir.IrNative;
import compiler.ir.model.Ir.IrCNative;
import compiler.ir.model.Ir.IrObject;
import compiler.ir.model.Ir.IrProgram;
import compiler.ir.model.Ir.IrType;
import compiler.ir.verify.IrVerifier;
import compiler.hl.incremental.HlSymbolRequest;
import compiler.hl.incremental.HlSymbolRequest.HlRemap;
import compiler.ir.model.SourceProvenance;
import compiler.core.AllocationMeter;
import compiler.core.AllocationMeter.PhaseAllocation;
import compiler.core.StdlibNames;

typedef HlLowerMetrics = {
	final allocationPhases:Array<PhaseAllocation>;
	final verificationMs:Float;
	final metadataMs:Float;
	final functionsMs:Float;
	final debugMs:Float;
	final finalizationMs:Float;
}

typedef MeasuredHlCode = {
	/** The tables a relocatable lowering relocated its functions into, for the next build to extend; null for any other. */
	final tables:Null<compiler.hl.incremental.HlRelocations.HlLoweredTables>;

	/** How many functions were kept from the cache instead of lowered. */
	final reusedFunctions:Int;

	/** How many of them got other indices than they were lowered with. */
	final movedFunctions:Int;

	final code:HlCode;
	final metrics:HlLowerMetrics;
}

/** Lowers verified SSA IR into indexed HashLink types, registers, and opcodes. */
@:nullSafety(Strict)
class HlLower {
	final code:HlCode;
	final symbols:HlSymbolTable;
	final functionIndices:Map<String, Int> = [];
	final objectTypeIndices:Map<String, Int> = [];

	/** Everything lowering a function may learn about an object type; see `HlLoweringView`. */
	final view:HlLoweringView;

	/** The requests the function being lowered makes, when lowering records them. */
	var recordedKeys:Null<Array<Int>>;

	/** The answers of `recordedKeys`, in step. */
	var recordedAnswers:Array<Int> = [];

	/** The numbers requests are recorded under (`HlRequestKeys`): the session's, or this lowering's own. */
	final requestKeys:compiler.hl.incremental.HlRequestKeys;

	/** The next label `freshLabel` gives, past the function's last block id. */
	var nextLabel = 0;

	/** The tables of the function being lowered, their storage kept from one function to the next. */
	final scratch = new HlLowerScratch();

	/** The body of the function being lowered (`lowerFunction`), null before the first; its methods read it through `requireBody`. */
	var body:Null<IrBody> = null;

	/** `allocateTemporary`, made once: the scalar locals of each function take their registers through it. */
	final allocateRegister:IrType->Int;

	/**
	 * A lowering for an assembly that does not trust its cache records each function's requests and keeps the functions as
	 * lowered (`HlCode.relocations`), for the sections to name what they use by key and a later build to keep them. A live
	 * build, which trusts its cache, and a lowering by itself (`lower`) do neither.
	 */
	final relocatable:Bool;

	/**
	 * The run of live builds this one belongs to (`HlRelocations.chain`): a live build's functions keep their slots and indices,
	 * so they have identity relocations, and its sections are kept from the last build of the run.
	 */
	final liveChain:Int;

	/** The answers the requests get in this build's tables. */
	var answers:Null<compiler.hl.incremental.HlRequestAnswers> = null;

	/** Where this build's tables hold the indices of the function being relocated. */
	final remap = new HlRemap();

	/** A live build's published functions, kept by name instead of lowered again (`trustCache`); filled with this build's at the end. */
	final published:Null<compiler.hl.incremental.HlPublishedFunctions>;

	/** The tables the last plain build relocated its functions into, which this one extends when they fit (`HlLoweredTables`). */
	final previousTables:Null<compiler.hl.incremental.HlRelocations.HlLoweredTables>;

	/** The tables this build relocated its functions into, once lowered; null unless it is relocatable. */
	var loweredTables:Null<compiler.hl.incremental.HlRelocations.HlLoweredTables> = null;

	/**
	 * What the steps around lowering work out from each function, kept in the session's database (`HlFunctionQueries`), with what a
	 * plain build's lowering made of each function.
	 */
	final queries:Null<compiler.hl.incremental.HlFunctionQueries>;

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

	/** The owner `Class.field` was found on, by `Class.field`, for the field slot request. */
	final interfaceBases:Map<String, Array<String>> = [];

	final enumTypeIndices:Map<String, Int> = [];
	final cNatives:Map<String, IrCNative> = [];
	final cDispatchNatives:Array<IrNative> = [];
	final preparedRuntimeNatives:Null<Array<IrNative>>;

	/** Lowers `program` by itself; its locations are placed in `sources`, which IR made from a compiler's modules needs. */
	public static function lower(program:IrProgram, ?indices:Map<String, Int>,
			?sources:compiler.core.SourceAnchor.SourceAnchors):HlCode {
		IrVerifier.verify(program);
		var lowerer = new HlLower(program, new HlSymbolTable(), null);
		if (sources != null)
			lowerer.code.sources = sources;
		var code = lowerer.lowerProgram(program);
		if (indices != null)
			for (name => index in lowerer.functionIndices)
				indices.set(name, index);
		return code;
	}

	public static function lowerStableMeasured(program:IrProgram, symbols:HlSymbolTable, indices:Map<String, Int>,
			?regenerated:Array<String>, ?runtimeNatives:Array<IrNative>, fieldReserve:Int = 0,
			developmentMetadata:Bool = true,
			?published:compiler.hl.incremental.HlPublishedFunctions, irVerified:Bool = false,
			trustCache:Bool = false, ?frozen:String->Bool, checkReuse:Bool = false,
			?sources:compiler.core.SourceAnchor.SourceAnchors, liveChain:Int = 0,
			?queries:compiler.hl.incremental.HlFunctionQueries,
			?previousTables:compiler.hl.incremental.HlRelocations.HlLoweredTables):MeasuredHlCode {
		var startedAt = Sys.time() * 1000.0;
		var allocationAtStart = AllocationMeter.sample();
		var affected = regenerated;
		var cacheEmpty = published == null || !published.entries.iterator().hasNext();
		if (!trustCache || regenerated == null || cacheEmpty) {
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
			// Only regenerated functions are lowered again. Every other function's IR compared equal, provenance included, so its
			// cached lowering is still exact: its locations count from their declarations, which the writer places.
			var selected:Map<String, Bool> = [];
			for (name in regenerated)
				selected.set(name, true);
			IrVerifier.verifyFunctions(program, selected);
		}
		var verifiedAt = Sys.time() * 1000.0,
			allocationAfterVerification = AllocationMeter.sample(),
			lowerer = new HlLower(program, symbols, indices, affected, runtimeNatives, fieldReserve,
				developmentMetadata, published, trustCache, frozen, checkReuse, sources, !trustCache,
				liveChain, queries, previousTables),
			code = lowerer.lowerProgram(program);
		return {
			code: code,
			tables: lowerer.loweredTables,
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

	/** The cache is the caller's word: every entry not named in `regenerated` is kept as it is (live patching), with no IR comparison, and the entries made carry no requests. */
	final trustCache:Bool;

	/** Reserved slots a live build gives each object that can take fields later (see `reservedSlots`). */
	final fieldReserve:Int;

	/** What a lowered function depends on besides the program and the tables: the settings it is lowered with. */
	final settings:String;

	/** HashLink field indices by `object.field`, resolved against the types this build publishes. */
	/** The slot of an object field and the object that declares it, by type name then field name: a lookup makes no key string. */
	final fieldSlots:Map<String, Map<String, {index:Int, owner:String}>> = [];

	/** Objects a native signature reaches, which keep the layout the natives were built against (see `reservedSlots`). */
	var nativeVisible:Map<String, Bool> = [];

	final regenerated:Map<String, Bool> = [];
	final developmentMetadata:Bool;

	final typedInterfaces:HlTypedInterfaceTables;
	var metadataMs = 0.0;
	var functionsMs = 0.0;
	var debugMs = 0.0;
	var finalizationMs = 0.0;
	var allocationPhases:Array<PhaseAllocation> = [];

	function new(program:IrProgram, symbols:HlSymbolTable, indices:Null<Map<String, Int>>, ?regenerated:Array<String>,
			?runtimeNatives:Array<IrNative>, fieldReserve:Int = 0,
			developmentMetadata:Bool = true, ?published:compiler.hl.incremental.HlPublishedFunctions,
			trustCache:Bool = false,
			?frozen:String->Bool, checkReuse:Bool = false, ?sources:compiler.core.SourceAnchor.SourceAnchors,
			relocatable:Bool = false, liveChain:Int = 0, ?queries:compiler.hl.incremental.HlFunctionQueries,
			?previousTables:compiler.hl.incremental.HlRelocations.HlLoweredTables) {
		this.liveChain = liveChain;
		this.queries = queries;
		this.frozen = frozen;
		this.relocatable = relocatable;
		this.symbols = symbols;
		arrayBounds = new HlArrayBounds(compiler.ir.analysis.IrLoopBounds.pureNativeCalls(program.natives));
		this.checkingLinks = !trustCache && checkReuse;
		this.published = published;
		this.previousTables = previousTables;
		this.checkingTrust = trustCache && checkReuse;
		this.requestKeys = queries != null ? queries.requestKeys : new compiler.hl.incremental.HlRequestKeys();
		this.fieldReserve = fieldReserve;
		settings = "fieldReserve:" + fieldReserve + ",development:" + developmentMetadata;
		this.trustCache = trustCache;
		this.preparedRuntimeNatives = runtimeNatives;
		this.developmentMetadata = developmentMetadata;
		if (regenerated != null)
			for (name in regenerated)
				this.regenerated.set(name, true);
		code = new HlCode();
		if (sources != null)
			code.sources = sources;
		code.ints = symbols.ints;
		code.floats = symbols.floats;
		code.types = symbols.types;
		if (indices != null)
			for (name => index in indices)
				functionIndices.set(name, index);
		typedInterfaces = new HlTypedInterfaceTables(program);
		view = new HlLoweringView(typedInterfaces.keys, null, relocatable ? queries : null, settings, checkingLinks);
		// A live build keeps the code of the functions it does not regenerate without asking whether their facts still hold, so
		// it reads none about fields, which an edit elsewhere can change.
		if (!trustCache)
			view.useNonNullFields(compiler.ir.analysis.IrNonNullFields.of(program,
				queries == null ? null : queries.fieldStores, queries == null ? null : queries.fieldKeys,
				checkingLinks));
		// A method of this lowering, so taken once every field has its value.
		allocateRegister = allocateTemporary;
	}

	/** Lowers `program`, the program this lowering was made for. */
	function lowerProgram(program:IrProgram):HlCode {
		var runtimeNatives = preparedRuntimeNatives == null
			? discoverRuntimeNatives(program) : preparedRuntimeNatives.copy();
		for (native in program.cNatives) {
			cNatives.set(native.name, native);
			var arity = native.arguments.length;
			if (arity > 16)
				throw new InternalError('Ordinary C calls support at most 16 arguments, got $arity for "${native.name}"');
			if ((HlLoweringDecisions.isNativePointer(native.result) || HlLoweringDecisions.isManagedPointerBytes(native)
				|| HlLoweringDecisions.isUtf8Result(native))
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
			var pointerResult = HlLoweringDecisions.isNativePointer(native.result),
				bytesResult = HlLoweringDecisions.isManagedPointerBytes(native),
				aggregateResult = HlLoweringDecisions.isAggregateResult(native),
				utf8Result = HlLoweringDecisions.isUtf8Result(native),
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

	/**
	 * The runtime natives lowering `program` calls, in the order lowering meets them: the program's own, then those its functions'
	 * rows need. `memo` keeps each function's own list (`functionNatives`) while the function is the same object.
	 */
	public static function discoverRuntimeNatives(program:IrProgram, ?baseline:Array<IrNative>,
			?selected:Array<String>, ?memo:compiler.ir.reuse.IrFunctionValues<Array<IrNative>>):Array<IrNative> {
		var runtimeNatives = baseline == null ? program.natives.copy() : baseline.copy(),
			selectedNames:Map<String, Bool> = [];
		if (baseline != null)
			for (native in program.natives)
				ensureNative(runtimeNatives, native.name, native.arguments, native.result, native.library,
					native.symbol);
		if (Lambda.exists(program.functions,
			fn -> compiler.ir.passes.objects.IrTypedInterfaceDispatch.isDispatchEntry(fn.name))) {
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
			if (selected == null || selectedNames.exists(fn.name)) {
				var own = memo == null ? null : memo.of(fn);
				if (own == null) {
					own = functionNatives(fn);
					if (memo != null)
						own = memo.keep(fn, own);
				}
				for (native in own)
					ensureNative(runtimeNatives, native.name, native.arguments, native.result, native.library,
						native.symbol);
			}
		return runtimeNatives;
	}

	/** The runtime natives lowering the rows of `fn` calls, each once, in the order they come; they depend on nothing else. */
	static function functionNatives(fn:IrFunction):Array<IrNative> {
		var own:Array<IrNative> = [],
			valueArrayRead = compiler.ir.model.IrSymbol.of(HlLoweringDecisions.VALUE_ARRAY_READ_I32).id,
			body = fn.encodedBody();
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block), terminator = body.terminatorRow(block);
			while (row >= 0 && row != terminator) {
				discoverRowNatives(own, body, row, valueArrayRead);
				row = body.nextRow(row);
			}
		}
		return own.length == 0 ? NO_NATIVES : own;
	}

	@:processWide("the natives of a function whose rows call none, never changed")
	static final NO_NATIVES:Array<IrNative> = [];

	/** The runtime natives lowering row `row` of `body` calls, added to `runtimeNatives`. */
	static function discoverRowNatives(runtimeNatives:Array<IrNative>, body:IrBody, row:Int, valueArrayRead:Int):Void
		switch body.opcode(row) {
			case IrOpcode.CallClosure if ((switch (body.valueType(body.operand(row, 0))) {
				case IrType.Dyn: true;
				default: false;
			})): ensureNative(runtimeNatives, "__reflect_is_function", [IrType.Dyn], IrType.Bool);
			ensureNative(runtimeNatives, "__string_from_bytes", [IrType.RawPtr, IrType.I32], IrType.Bytes);
			case IrOpcode.PointerOffset:
				ensureNative(runtimeNatives, "__hl_bytes_offset", [IrType.RawPtr, IrType.I32], IrType.RawPtr, "std",
					"bytes_offset");
			case IrOpcode.IteratorNew:
				ensureNative(runtimeNatives, "__iterator_new", [IrType.Dyn], IrType.Abstract("realtime_iterator"));
			case IrOpcode.IteratorHasNext:
				ensureNative(runtimeNatives, "__iterator_has_next", [IrType.Abstract("realtime_iterator")],
					IrType.Bool);
			case IrOpcode.Call if (body.aux(row) == valueArrayRead && body.operandCount(row) == 5
				&& HlLoweringDecisions.readsInline(body.valueType(body.operand(row, 0)))):
				ensureNative(runtimeNatives, HlLoweringDecisions.VALUE_ARRAY_HEADER_TYPE, [], IrType.TypeRef);
				ensureNative(runtimeNatives, HlLoweringDecisions.VALUE_ARRAY_FORWARD_TYPE, [], IrType.TypeRef);
			case IrOpcode.ArrayGet:
				ensureRawArrayNative(runtimeNatives, body.valueType(body.operand(row, 0)), "check");
			case IrOpcode.ArraySet:
				ensureRawArrayNative(runtimeNatives, body.valueType(body.operand(row, 0)), "ensure");
			case IrOpcode.IteratorNext:
				var nextNative = HlLoweringDecisions.iteratorNextNative(body.valueType(body.output(row)));
				ensureNative(runtimeNatives, nextNative.name, [IrType.Abstract("realtime_iterator")],
					nextNative.result);
			default:
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
		var runtimeEnums = developmentMetadata
			? program.enums : compiler.ir.passes.enums.IrEnumRuntimeTypes.declarations(program,
			queries == null ? null : queries.enumUses, queries == null ? null : queries.database,
			checkingLinks || checkingTrust);
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
			var remainingInterfaces:Array<compiler.ir.model.Ir.IrInterface> = [];
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
		PeakProbe.mark("lower-metadata-done");
		var allocationAfterMetadata = AllocationMeter.sample();
		// A build extends the last one's tables when its settings, metadata and function layout are theirs (`HlLoweredTables`).
		var metadata = symbols.lengths(),
			slots = relocatable ? slotNames() : null,
			previousTables = relocatable ? this.previousTables : null,
			extended = previousTables;
		if (extended != null && slots != null && extended.fits(symbols, slots, settings))
			symbols.shareFrom(extended.tables);
		else
			extended = null;
		var chain = extended != null ? extended.chain : previousTables == null ? 0 : previousTables.chain + 1;
		var current = new compiler.hl.incremental.HlRequestAnswers(requestKeys, symbols, functionIndices,
			extended == null ? null : extended.answers);
		answers = current;
		var entries:Map<String, compiler.hl.incremental.HlLoweredFunction> = [],
			memos = relocatable ? queries : null,
			relocated:Array<compiler.hl.incremental.HlLoweredFunction> = [],
			relocatedTypes:Array<Int> = [],
			relocatedMoves:Array<Bool> = [];
		if (memos != null)
			memos.lowered.reserve(program.functions.length, compiler.ir.model.IrSymbol.functionKeysGiven());
		for (position in 0...program.functions.length) {
			var fn = program.functions[position];
			var kept = trustCache && !regenerated.exists(fn.name)
				&& published != null ? published.entries.get(fn.name) : null;
			if (kept != null) {
				// A frozen function is the code of an earlier signature, or of a lambda the program dropped, kept for closures that still call it; its stale IR lowered against this build is not what it holds.
				if (checkingTrust && (frozen == null || !frozen(fn.name)))
					verifyKept(fn, kept.fn);
				code.functions.push(kept.fn);
				entries.set(fn.name, kept);
				relocated.push(kept);
			} else {
				// A function whose IR is the one an earlier build lowered, and whose outside facts still hold, is kept as that build
				// made it: its requests are asked of this build's tables, which then hold what it names (`HlCode.relocations`).
				var slot = memos == null ? -1 : memos.lowered.slotFor(fn.symbol.functionKey()),
					entry = memos == null ? null : memos.loweredFor(slot, fn);
				if (entry != null) {
					var relocation = compiler.hl.incremental.HlLink.relocate(entry, current, remap);
					if (relocation != compiler.hl.incremental.HlLink.STALE) {
						var moves = relocation == compiler.hl.incremental.HlLink.MOVES;
						code.functions.push(entry.fn);
						relocated.push(entry);
						relocatedTypes.push(moves ? remap.get(compiler.hl.incremental.HlRequestKeys.TYPES,
							entry.fn.type) : entry.fn.type);
						relocatedMoves.push(moves);
						reusedFunctions++;
						if (moves)
							movedFunctions++;
						continue;
					}
				}
				try {
					if (relocatable) {
						recordedKeys = [];
						recordedAnswers = [];
						requestKeys.startFunction();
						if (memos != null)
							memos.lowered.begin(memos.database, slot);
						view.beginFunction();
					}
					var lowered = lowerFunction(loweringBody(fn));
					if (trustCache) {
						var entry = new compiler.hl.incremental.HlLoweredFunction(fn.name, fn, lowered, [], []);
						code.functions.push(lowered);
						entries.set(fn.name, entry);
						relocated.push(entry);
					} else if (relocatable) {
						// The function's requests were recorded from its start.
						var keys = recordedKeys;
						if (keys == null)
							throw new InternalError("HashLink lowering: a function's requests were not recorded");
						var entry = new compiler.hl.incremental.HlLoweredFunction(fn.name, fn, lowered, keys,
							recordedAnswers);
						view.endFunction();
						recordedKeys = null;
						if (checkingLinks)
							verifyAnswers(entry);
						if (memos != null)
							memos.lowered.endChanged(memos.database, slot, entry);
						relocated.push(entry);
						relocatedTypes.push(lowered.type);
						relocatedMoves.push(false);
						code.functions.push(lowered);
					} else
						code.functions.push(lowered);
				} catch (error:InternalError) {
					throw new InternalError('HashLink lowering failed for ${fn.name}: ${error.message}', error.span);
				} catch (missing:HlMissingEntity) {
					throw new InternalError('HashLink lowering failed for ${fn.name}: ${missing.message}');
				}
			}
		}
		if (skippedKept.length > 0) {
			// Once per process, a few names: a test driver reads a child's stderr after it exits, and a line per build fills the pipe.
			skippedKeptTotal += skippedKept.length;
			if (!reportedSkips) {
				reportedSkips = true;
				Sys.stderr()
					.writeString('--check-reuse: kept functions could not be lowered again because their objects or fields are gone, e.g. ${skippedKept.slice(0, 3).join(", ")}\n');
			}
		}
		// The String constants' globals each hold the literal's String: its data, its length and its hash, which a string map
		// computes and keeps on first use. Extended tables keep the last build's while it holds the same literals.
		if (extended != null && symbols.sameStringConstants(extended.tables))
			code.constants = extended.constants;
		else
			for (literal in symbols.stringConstantGlobals())
				code.constants.push({
					global: literal.global,
					fields: [
						internString(literal.value),
						internInt(HlSymbolTable.utf16Length(literal.value)),
						internInt(0)
					]
				});
		var live = published;
		if (live != null && trustCache)
			live.entries = entries;
		if (slots != null)
			loweredTables = new compiler.hl.incremental.HlRelocations.HlLoweredTables(metadata, slots, settings,
				symbols,
				current, code.constants, chain);
		var functionsDoneAt = Sys.time() * 1000.0;
		PeakProbe.mark("lower-functions-done");
		var allocationAfterFunctions = AllocationMeter.sample();
		var allocationAfterSpanGroups = allocationAfterFunctions;
		if (developmentMetadata) {
			var spanGroups:Array<compiler.hl.HlWriter.HlOpcodeSourceSpanGroup> = [for (fn in code.functions) {
				index: fn.functionIndex,
				locations: fn.debugLocations,
				opcodes: fn.opcodes
			}];
			allocationAfterSpanGroups = AllocationMeter.sample();
			// The groups only point at the functions' locations; the section is encoded when the module is written. It captures
			// the sources, not `code`, a field: that would keep this lowerer alive with every module.
			var sources = code.sources;
			code.debugSections.push(HlDebugSection.lazy(HlWriter.OPCODE_SOURCE_SPANS, 2, 0,
				() -> HlWriter.encodeOpcodeSourceSpanGroups(spanGroups, sources), HlLz4.FAST));
		}
		var debugDoneAt = Sys.time() * 1000.0;
		var allocationAfterDebug = AllocationMeter.sample();

		code.entryPoint = requireFunction(program.entryPoint);
		code.ints = symbols.ints;
		code.floats = symbols.floats;
		code.strings = symbols.stringTable();
		code.types = symbols.types;
		code.globals = symbols.globalTable();
		code.functionNames = [for (fn in program.functions) fn.name];
		code.globalNames = symbols.globalNames();
		if (trustCache)
			code.typeKeys = symbols.renamedTypeKeys();
		if (relocatable)
			code.relocations = new compiler.hl.incremental.HlRelocations(relocated,
				[for (fn in program.functions) requireFunction(fn.name)], relocatedTypes, relocatedMoves, current,
				chain);
		else if (trustCache)
			code.relocations = compiler.hl.incremental.HlRelocations.identity(relocated, liveChain);
		var finalizedAt = Sys.time() * 1000.0;
		var allocationAfterFinalize = AllocationMeter.sample();
		allocationPhases = [
			AllocationMeter.delta("backend-metadata", allocationAtStart, allocationAfterMetadata),
			AllocationMeter.delta("backend-functions", allocationAfterMetadata, allocationAfterFunctions),
			AllocationMeter.delta("backend-debug", allocationAfterFunctions, allocationAfterDebug),
			AllocationMeter.delta("backend-debug-span-groups", allocationAfterFunctions, allocationAfterSpanGroups),
			AllocationMeter.delta("backend-debug-encode", allocationAfterSpanGroups, allocationAfterDebug),
			AllocationMeter.delta("backend-finalize", allocationAfterDebug, allocationAfterFinalize)
		];
		metadataMs = metadataDoneAt - startedAt;
		functionsMs = functionsDoneAt - metadataDoneAt;
		debugMs = debugDoneAt - functionsDoneAt;
		finalizationMs = finalizedAt - debugDoneAt;
	}

	/** The function layout as the name in each slot. */
	function slotNames():Array<String> {
		var names:Array<String> = [];
		for (name => index in functionIndices) {
			while (names.length <= index)
				names.push("");
			names[index] = name;
		}
		return names;
	}

	/** What a function's code names is what its requests answer in the tables it was lowered into. */
	function verifyAnswers(entry:compiler.hl.incremental.HlLoweredFunction):Void {
		var current = answers;
		if (current == null)
			throw new InternalError("HashLink lowering: checking answers without them");
		for (index in 0...entry.keys.length)
			if (current.answer(entry.keys[index]) != entry.answers[index])
				throw new InternalError('--check-reuse: ${entry.name} recorded request ${Std.string(requestKeys.request(entry.keys[index]))} with answer ${entry.answers[index]}, the tables answer ${current.answer(entry.keys[index])}');
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
				symbols.stringCount,
				symbols.types.length,
				symbols.globalCount
			].join(",");
		var before = sizes();
		var fresh:HlFunction;
		try
			fresh = lowerFunction(loweringBody(fn))
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

	/**
	 * A scalar read of a value array element, inline (`VALUE_ARRAY_ACCESS.md`): with the array's header resolved to its
	 * value array (`valueArrayView`), an index in range, of an element present (for arrays with validity bits), loads the
	 * slot from the scalar lane, `index * stride + offset`; anything else calls the native, which raises its errors as
	 * before.
	 */
	function lowerValueArrayRead(row:Int, output:IrValueId, slot:InlineValueSlot, block:Int,
			instructions:Array<HlInstruction>, registers:Array<Int>, registerTypes:Array<Int>):Void {
		var body = requireBody();
		var arrayValue = body.operand(row, 0),
			indexValue = body.operand(row, 1),
			array = requireRegister(arrayValue, registers),
			index = requireRegister(indexValue, registers),
			destination = defineRegister(output, registers, registerTypes),
			view = valueArrayView(arrayValue, instructions, registers, registerTypes),
			slow = freshLabel(),
			done = freshLabel(),
			size = temporaryRegister(IrType.I32, registerTypes),
			data = temporaryRegister(IrType.Bytes, registerTypes),
			position = temporaryRegister(IrType.I32, registerTypes);
		instructions.push(HlInstruction.JumpNull(view.array, slow));
		// A loop that runs the index up to the array's length, and resizes nothing, proved it in range.
		if (!arrayBounds.provenByLoop(arrayValue, indexValue, block)) {
			instructions.push(HlInstruction.GetMem(size, view.array,
				constantRegister(HlLoweringDecisions.ARRAY_SIZE_OFFSET, instructions, registerTypes)));
			instructions.push(HlInstruction.JumpUnsignedGreaterOrEqual(index, size, slow));
		}
		// An element of an array with validity bits is read only once it was written; else the native raises its error.
		if (HlLoweringDecisions.hasValidity(body.valueType(arrayValue))) {
			var bits = temporaryRegister(IrType.Bytes, registerTypes),
				byte = temporaryRegister(IrType.I32, registerTypes),
				byteIndex = temporaryRegister(IrType.I32, registerTypes),
				bit = temporaryRegister(IrType.I32, registerTypes);
			instructions.push(HlInstruction.GetMem(bits, view.array,
				constantRegister(HlLoweringDecisions.VALUE_ARRAY_VALIDITY_OFFSET, instructions, registerTypes)));
			instructions.push(HlInstruction.UnsignedShiftRight(byteIndex, index,
				constantRegister(3, instructions, registerTypes)));
			instructions.push(HlInstruction.Add(byteIndex, byteIndex,
				constantRegister(HlLoweringDecisions.LANE_HEADER_BYTES, instructions, registerTypes)));
			instructions.push(HlInstruction.GetI8(byte, bits, byteIndex));
			instructions.push(HlInstruction.BitAnd(bit, index, constantRegister(7, instructions, registerTypes)));
			instructions.push(HlInstruction.UnsignedShiftRight(byte, byte, bit));
			instructions.push(HlInstruction.BitAnd(byte, byte, constantRegister(1, instructions, registerTypes)));
			instructions.push(HlInstruction.JumpEqual(byte, constantRegister(0, instructions, registerTypes), slow));
		}
		instructions.push(HlInstruction.GetMem(data, view.array,
			constantRegister(HlLoweringDecisions.ARRAY_DATA_OFFSET, instructions, registerTypes)));
		instructions.push(HlInstruction.Mul(position, index, view.strideBytes));
		// The lane starts with a type word; the payload follows it.
		instructions.push(HlInstruction.Add(position, position,
			constantRegister(HlLoweringDecisions.LANE_HEADER_BYTES + (slot.offset >> 3), instructions, registerTypes)));
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
		instructions.push(HlInstruction.CallN(destination, requireFunction(HlLoweringDecisions.VALUE_ARRAY_READ_I32),
			operandRegisters(row, 0, registers)));
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
	function valueArrayView(array:IrValueId, instructions:Array<HlInstruction>, registers:Array<Int>,
			registerTypes:Array<Int>):ValueArrayView {
		var known = definedViews.get(array) ?? valueArrayViews.get(array);
		if (known != null)
			return known;
		var view = resolveValueArrayView(array, instructions, registers, registerTypes);
		valueArrayViews.set(array, view);
		return view;
	}

	/**
	 * Resolves `array`'s view where the array value is defined (an argument or phi at its block's start, any other value
	 * right after its instruction), so it dominates every read of the value (`definedViews`).
	 */
	function defineValueArrayView(array:IrValueId, instructions:Array<HlInstruction>, registers:Array<Int>,
			registerTypes:Array<Int>):Void
		if (hasViewedArrays && viewedArrays.exists(array) && !definedViews.exists(array))
			definedViews.set(array, resolveValueArrayView(array, instructions, registers, registerTypes));

	function resolveValueArrayView(array:IrValueId, instructions:Array<HlInstruction>, registers:Array<Int>,
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
		runtimeTypePointer(expectedPointer, HlLoweringDecisions.VALUE_ARRAY_HEADER_TYPE, instructions, registerTypes);
		instructions.push(HlInstruction.JumpNotEqual(actualPointer, expectedPointer, forwarded));
		instructions.push(HlInstruction.UnsafeCast(view.array, header));
		instructions.push(HlInstruction.Jump(resolved));
		instructions.push(HlInstruction.Label(forwarded));
		runtimeTypePointer(expectedPointer, HlLoweringDecisions.VALUE_ARRAY_FORWARD_TYPE, instructions, registerTypes);
		instructions.push(HlInstruction.JumpNotEqual(actualPointer, expectedPointer, absent));
		var raw = temporaryRegister(IrType.Bytes, registerTypes);
		instructions.push(HlInstruction.UnsafeCast(raw, header));
		instructions.push(HlInstruction.GetMem(view.array, raw,
			constantRegister(HlLoweringDecisions.ARRAY_DATA_OFFSET, instructions, registerTypes)));
		instructions.push(HlInstruction.Jump(resolved));
		instructions.push(HlInstruction.Label(absent));
		instructions.push(HlInstruction.LoadNull(view.array));
		instructions.push(HlInstruction.Label(resolved));
		instructions.push(HlInstruction.JumpNull(view.array, strided));
		var strideBits = temporaryRegister(IrType.I32, registerTypes);
		instructions.push(HlInstruction.GetMem(strideBits, view.array,
			constantRegister(HlLoweringDecisions.VALUE_ARRAY_STRIDE_OFFSET, instructions, registerTypes)));
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

	static function ensureNative(natives:Array<IrNative>, name:String, arguments:Array<IrType>, result:IrType,
			?library:String, ?symbol:String):Void {
		var nativeLibrary = library ?? "haxeon_runtime", nativeSymbol = symbol ?? name;
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

	/** The body `fn` is lowered from: its own (`IrFunction.encodedBody`), with an edge block on each branch into a block with phis. */
	function loweringBody(fn:IrFunction):IrBody
		return scratch.phiEdges.splitBody(fn.encodedBody(scratch.bodyBuilder), scratch.bodyBuilder);

	/** The body of the function being lowered, which every method that lowers part of it reads. */
	inline function requireBody():IrBody {
		var current = body;
		if (current == null)
			throw new InternalError("No function is being lowered");
		return current;
	}

	function lowerFunction(source:IrBody):HlFunction {
		this.body = source;
		var body = source;
		nextLabel = 0;
		for (block in 0...body.blockCount())
			if (body.blockId(block) >= nextLabel)
				nextLabel = body.blockId(block) + 1;
		// The analyses read the body as it is, so they share its graph.
		var graph = scratch.graph.reset(body),
			receiverClass = compiler.ir.analysis.IrNonNullFacts.receiverClass(body),
			receiver = receiverClass != null
				&& compiler.ir.analysis.IrNonNullFacts.isMethodReceiver(body, view.object(receiverClass)),
			nonNull = compiler.ir.analysis.IrNonNullFacts.analyzeBody(body, true, graph, scratch.nonNull, receiver,
				view.nonNull),
			exactTypes = scratch.exactTypes.reset(body, graph);
		// Tables about values are indexed by value id, which is dense within a function: a register (-1 before its
		// definition), whether the value is a null constant, and how many operands read it.
		var valueLimit = body.valueLimit();
		var registers = compiler.ir.model.IrPassScratch.filledInts(scratch.registers, valueLimit, -1);
		var registerTypes = scratch.registerTypes;
		registerTypes.resize(0);
		var nullValues = compiler.ir.model.IrPassScratch.filledBools(scratch.nullValues, valueLimit, false);
		var hasPointerOffsets = false;
		hasFoldedAddresses = false;
		for (index in 0...body.argumentCount())
			defineRegister(body.argument(index), registers, registerTypes);
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block), terminator = body.terminatorRow(block);
			while (row >= 0 && row != terminator) {
				var output = body.output(row);
				if (output.exists())
					defineRegister(output, registers, registerTypes);
				switch body.opcode(row) {
					case IrOpcode.ConstNull:
						nullValues[output] = true;
					case IrOpcode.PointerOffset:
						hasPointerOffsets = true;
					default:
				}
				row = body.nextRow(row);
			}
		}
		var scalarOptionals = scratch.scalarLocals;
		scalarOptionals.reset(body, view, allocateRegister);
		var uses = compiler.ir.model.IrPassScratch.filledInts(scratch.uses, valueLimit, 0);
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				for (operand in 0...body.operandCount(row))
					uses[body.operand(row, operand)]++;
				row = body.nextRow(row);
			}
		}
		if (hasPointerOffsets)
			foldPointerOffsets(uses);
		// An array boxed only to be cast back to an array, as a coercion between array types does, is the same HashLink array
		// (`HlType.Array` carries no element type): the cast takes the array itself unchecked, and the box is not made.
		var arrayRecasts = compiler.ir.model.IrPassScratch.filledInts(scratch.arrayRecasts, valueLimit, -1),
			unboxedArrays = scratch.unboxedArrays;
		unboxedArrays.clear();
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block), terminator = body.terminatorRow(block);
			while (row >= 0 && row != terminator) {
				if (HlLoweringDecisions.isArrayRecast(body, row, uses)) {
					arrayRecasts[body.output(body.nextRow(row))] = body.operand(row, 0);
					unboxedArrays.add(body.output(row));
				}
				row = body.nextRow(row);
			}
		}
		var catchValues = compiler.ir.model.IrPassScratch.filledInts(scratch.catchValues, nextLabel, -1);
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block), terminator = body.terminatorRow(block);
			while (row >= 0 && row != terminator) {
				switch body.opcode(row) {
					case IrOpcode.Phi:
						defineRegister(body.output(row), registers, registerTypes);
					case IrOpcode.Catch:
						catchValues[body.blockId(block)] = body.output(row);
						defineRegister(body.output(row), registers, registerTypes);
					default:
				}
				row = body.nextRow(row);
			}
		}
		groupPhiMoves();

		// Each value's debug bindings, in the order the body has them: the first, and from each the next for the same value.
		var firstBinding = compiler.ir.model.IrPassScratch.filledInts(scratch.firstBinding, valueLimit, -1),
			nextBinding = compiler.ir.model.IrPassScratch.filledInts(scratch.nextBinding, body.bindingCount(), -1),
			index = body.bindingCount();
		while (index > 0) {
			index--;
			var value = body.bindingValue(index);
			nextBinding[index] = firstBinding[value];
			firstBinding[value] = index;
		}
		var debugAssignments = scratch.debugAssignments, assignmentBindings = scratch.assignmentBindings;
		debugAssignments.resize(0);
		assignmentBindings.resize(0);
		for (argument in 0...body.argumentCount()) {
			var binding = firstBinding[body.argument(argument)];
			while (binding >= 0) {
				debugAssignments.push({name: internString(body.bindingName(binding)), position: -1, scopeEnd: -1});
				assignmentBindings.push(binding);
				binding = nextBinding[binding];
			}
		}
		// The array values read inline get their value array view where they are defined (`defineValueArrayView`).
		viewedArrays.clear();
		definedViews.clear();
		hasViewedArrays = false;
		arrayBounds.startFunction(body, graph);
		var valueArrayRead = compiler.ir.model.IrSymbol.of(HlLoweringDecisions.VALUE_ARRAY_READ_I32).id;
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				if (body.opcode(row) == IrOpcode.Call && body.aux(row) == valueArrayRead
					&& HlLoweringDecisions.inlineValueArraySlot(body, row) != null) {
					viewedArrays.set(body.operand(row, 0), true);
					hasViewedArrays = true;
				}
				row = body.nextRow(row);
			}
		}
		var instructions = scratch.instructions, debugLocations = scratch.debugLocations;
		instructions.resize(0);
		debugLocations.resize(0);
		// A jump to the block written next is left out: control falls through to it.
		var emitted = layOut(), layoutPositions = scratch.layoutPositions;
		for (layoutIndex in 0...emitted.length) {
			var block = emitted[layoutIndex],
				id = body.blockId(block),
				fallsThroughTo = layoutIndex + 1 < emitted.length ? body.blockId(emitted[layoutIndex + 1]) : -1,
				terminator = body.terminatorRow(block),
				last = body.lastRow(block);
			if (last == terminator)
				last = terminator >= 0 ? body.previousRow(terminator) : -1;
			instructions.push(HlInstruction.Label(id));
			debugLocations.push(debugLocation(blockProvenance(body, block)));
			// Arguments and phis are defined when the block starts: their value array views are resolved here.
			if (hasViewedArrays) {
				var viewStart = instructions.length;
				if (block == 0)
					for (argument in 0...body.argumentCount())
						defineValueArrayView(body.argument(argument), instructions, registers, registerTypes);
				var row = body.firstRow(block);
				while (row >= 0 && row != terminator) {
					if (body.opcode(row) == IrOpcode.Phi)
						defineValueArrayView(body.output(row), instructions, registers, registerTypes);
					row = body.nextRow(row);
				}
				appendDebugLocations(debugLocations, instructions.length - viewStart, blockProvenance(body, block));
			}
			// A comparison that ends its block and feeds only that block's branch becomes the branch itself, with
			// no Bool in between: the loop test then costs one compare-and-jump instead of a compare, two moves and a test.
			var fusedCondition = -1,
				fusedComparison:Null<HlInstruction> = null,
				fusedFloat = false;
			if (terminator >= 0 && last >= 0 && body.opcode(terminator) == IrOpcode.Branch) {
				var condition = body.operand(terminator, 0);
				if (uses[condition] == 1 && firstBinding[condition] < 0
					&& (body.output(last):Int) == (condition:Int))
					switch body.opcode(last) {
						case IrOpcode.Less, IrOpcode.LessEqual, IrOpcode.Equal:
							fusedCondition = condition;
						case IrOpcode.Call if (body.operandCount(last) == 2
							&& isPointerTest(HlLoweringDecisions.classifyCall(body.symbol(last).name))):
							fusedCondition = condition;
						default:
					}
			}
			arrayBounds.startBlock();
			elementOffsets.clear();
			valueArrayViews.clear();
			var row = body.firstRow(block);
			while (row >= 0 && row != terminator) {
				var instructionStart = instructions.length, opcode = body.opcode(row);
				arrayBounds.step(row);
				var output = body.output(row), receiver = HlLoweringDecisions.receiverOf(body, row);
				if (receiver.exists() && scalarOptionals.get(receiver) == null && !nonNull.has(row))
					instructions.push(HlInstruction.NullCheck(requireRegister(receiver, registers)));
				lowerRow(row, opcode, output, id, fusedCondition, registers, registerTypes, instructions, uses,
					nonNull, exactTypes, firstBinding, arrayRecasts, catchValues);
				if (fusedCondition >= 0 && (output:Int) == fusedCondition && fusedPending != null) {
					fusedComparison = fusedPending;
					fusedFloat = fusedPendingFloat;
					fusedPending = null;
				}
				if (output.exists())
					defineValueArrayView(output, instructions, registers, registerTypes);
				appendDebugLocations(debugLocations, instructions.length - instructionStart, body.provenance(row));
				if (output.exists() && instructions.length > instructionStart)
					assignBindings(firstBinding[output], nextBinding, instructionStart);
				row = body.nextRow(row);
			}
			if (terminator < 0)
				throw new InternalError('Reachable IR block $id has no terminator');
			var terminatorStart = instructions.length;
			switch body.opcode(terminator) {
				case IrOpcode.Unreachable:
					// The fatal runtime native aborts the process and is not an exception, so no Haxe code can catch it. The block still needs an
					// ending the bytecode accepts: a throw of null that is never reached.
					instructions.push(HlInstruction.Call0(temporaryRegister(IrType.Void, registerTypes),
						requireFunction("__unreachable")));
					var neverThrown = temporaryRegister(IrType.Dyn, registerTypes);
					instructions.push(HlInstruction.LoadNull(neverThrown));
					instructions.push(HlInstruction.Throw(neverThrown));
				case IrOpcode.Return:
					instructions.push(HlInstruction.Return(requireRegister(body.operand(terminator, 0), registers)));
				case IrOpcode.Throw:
					instructions.push(HlInstruction.Throw(requireRegister(body.operand(terminator, 0), registers)));
				case IrOpcode.Rethrow:
					instructions.push(HlInstruction.Rethrow(requireRegister(body.operand(terminator, 0), registers)));
				case IrOpcode.Jump:
					var target = body.aux(terminator);
					if (hasPhiMoves(id, target)) {
						emitPhiMoves(id, registers, registerTypes, instructions);
						for (write in 0...scratch.writtenValues.length)
							assignBindings(firstBinding[scratch.writtenValues[write]], nextBinding,
								scratch.writtenPositions[write]);
					}
					if (target != fallsThroughTo)
						instructions.push(HlInstruction.Jump(target));
				case IrOpcode.Branch:
					var condition = body.operand(terminator, 0),
						yes = body.auxInt(terminator, 0),
						no = body.auxInt(terminator, 1);
					if (hasPhiMoves(id, yes) || hasPhiMoves(id, no))
						throw new InternalError("Phi elimination requires split critical edges");
					if (yes == fallsThroughTo && no != fallsThroughTo)
						// The taken side is written next: jump to the other side on the complement, and fall through.
						instructions.push(fusedComparison != null ? complementJump(fusedComparison, no,
							fusedFloat) : HlInstruction.JumpFalse(requireRegister(condition, registers), no));
					else {
						if (fusedComparison != null)
							instructions.push(withJumpTarget(fusedComparison, yes));
						else
							instructions.push(HlInstruction.JumpTrue(requireRegister(condition, registers), yes));
						if (no != fallsThroughTo)
							instructions.push(HlInstruction.Jump(no));
					}
				case IrOpcode.Switch:
					var count = body.successorCount(terminator), otherwise = body.auxInt(terminator, 0);
					for (index in 0...count)
						if (hasPhiMoves(id, body.successor(terminator, index)))
							throw new InternalError("Phi elimination requires split critical edges");
					// HashLink's jump table takes only forward offsets: a target laid out before this block is reached through a
					// jump placed after the table. Values outside it fall through to the jump to `otherwise`.
					var stubLabels = scratch.stubLabels, stubTargets = scratch.stubTargets, entries:Array<Int> = [];
					stubLabels.resize(0);
					stubTargets.resize(0);
					for (index in 0...count - 1) {
						var target = body.auxInt(terminator, 2 + index);
						if (layoutPositions[target] > layoutIndex)
							entries.push(target);
						else {
							var stub = -1;
							for (existing in 0...stubTargets.length)
								if (stubTargets[existing] == target)
									stub = stubLabels[existing];
							if (stub < 0) {
								stub = freshLabel();
								stubLabels.push(stub);
								stubTargets.push(target);
							}
							entries.push(stub);
						}
					}
					instructions.push(HlInstruction.Switch(requireRegister(body.operand(terminator, 0), registers),
						entries));
					if (otherwise != fallsThroughTo || stubLabels.length > 0)
						instructions.push(HlInstruction.Jump(otherwise));
					for (stub in 0...stubLabels.length) {
						instructions.push(HlInstruction.Label(stubLabels[stub]));
						instructions.push(HlInstruction.Jump(stubTargets[stub]));
					}
				default:
					throw new InternalError('IR body row $terminator is not a terminator');
			}
			appendDebugLocations(debugLocations, instructions.length - terminatorStart, body.provenance(terminator));
		}

		var scopedAssignments:Array<HlDebugAssignment> = [],
			scopeEnds = compiler.ir.model.IrPassScratch.filledInts(scratch.scopeEnds, body.bindingCount(), -2);
		for (index in 0...debugAssignments.length) {
			var assignment = debugAssignments[index];
			scopedAssignments.push({
				name: assignment.name,
				position: assignment.position,
				scopeEnd: assignment.position < 0 ? -1 : scopeEndPosition(assignmentBindings[index], debugLocations,
					assignment.position, instructions.length, scopeEnds)
			});
		}
		var name = body.name, argumentCount = body.argumentCount(), result = IrTypeIds.type(body.result);
		var key = view.typedInterfaceKey(name);
		if (key != null) {
			var handleType = IrType.Abstract(HlTypedInterfaceTables.SLOT_TYPE),
				handle = temporaryRegister(handleType, registerTypes),
				keyRegister = temporaryRegister(IrType.TypeRef, registerTypes),
				receiver = temporaryRegister(IrType.Dyn, registerTypes),
				entry = temporaryRegister(IrType.Abstract(HlTypedInterfaceTables.ENTRY_TYPE), registerTypes),
				callable = temporaryRegister(IrType.Function([IrType.Dyn]
					.concat([for (i in 1...argumentCount) body.valueType(body.argument(i))]), result),
					registerTypes),
				resultRegister = temporaryRegister(result, registerTypes),
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
				HlInstruction.CallClosure(resultRegister, callable,
					[receiver].concat([for (i in 1...argumentCount) i])),
				HlInstruction.Return(resultRegister),
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
		var allocated = developmentMetadata ? registerTypes : scratch.registerAllocation.run(instructions,
			registerTypes, argumentCount);
		var lowered = new HlFunction(internFunctionType([for (i in 0...argumentCount) body.valueType(body.argument(i))],
			result), requireFunction(name), allocated == scratch.registerTypes ? allocated.copy() : allocated,
			instructions.copy(), debugLocations.copy(), scopedAssignments);
		scratch.release();
		return lowered;
	}

	/** The comparison `lowerRow` made of the row that ends its block and feeds its branch, and whether it compares floats. */
	var fusedPending:Null<HlInstruction> = null;

	var fusedPendingFloat = false;

	/**
	 * Records, at `position`, an assignment of every binding from `binding` on (through `nextBinding`) that has none there yet.
	 * Assignments are recorded in position order, so those at `position` are the last ones.
	 */
	function assignBindings(binding:Int, nextBinding:Array<Int>, position:Int):Void {
		var body = requireBody();
		var debugAssignments = scratch.debugAssignments, assignmentBindings = scratch.assignmentBindings;
		while (binding >= 0) {
			var identity = body.bindingIdentity(binding), seen = false, index = debugAssignments.length;
			while (index > 0 && debugAssignments[index - 1].position == position) {
				index--;
				if (body.bindingIdentity(assignmentBindings[index]) == identity) {
					seen = true;
					break;
				}
			}
			if (!seen) {
				debugAssignments.push({name: internString(body.bindingName(binding)), position: position,
					scopeEnd: -1});
				assignmentBindings.push(binding);
			}
			binding = nextBinding[binding];
		}
	}

	/** A register for a value of type `type` that no IR value has, in the function being lowered (`allocateRegister`). */
	function allocateTemporary(type:IrType):Int
		return temporaryRegister(type, scratch.registerTypes);

	/** Lowers instruction row `row` of block `block`, which has opcode `opcode` and defines `output`. */
	function lowerRow(row:Int, opcode:IrOpcode, output:IrValueId, block:Int, fusedCondition:Int, registers:Array<Int>,
			registerTypes:Array<Int>, instructions:Array<HlInstruction>, uses:Array<Int>,
			nonNull:compiler.ir.model.IrPassScratch.IrValueMarks, exactTypes:compiler.ir.analysis.IrExactTypeFacts,
			firstBinding:Array<Int>, arrayRecasts:Array<Int>, catchValues:Array<Int>):Void {
		var body = requireBody();
		var scalarOptionals = scratch.scalarLocals;
		switch opcode {
			case IrOpcode.Phi:
			case IrOpcode.ClassId:
				throw new InternalError('internal error: ClassId is lowered by the interface dispatch (docs/design/INTERFACE_VALUES.md), which HashLink does not have yet');
			case IrOpcode.ConstVoid:
				defineRegister(output, registers, registerTypes);
			case IrOpcode.ConstInt:
				instructions.push(HlInstruction.LoadInt(defineRegister(output, registers, registerTypes),
					internInt(body.aux(row))));
			case IrOpcode.ConstFloat:
				instructions.push(HlInstruction.LoadFloat(defineRegister(output, registers, registerTypes),
					internFloat(body.float(row))));
			case IrOpcode.ConstString:
				lowerStringLiteral(defineRegister(output, registers, registerTypes), body.string(row), registerTypes,
					instructions);
			case IrOpcode.StaticDataAddress:
				// RuntimeData is a Wasm-only intrinsic. The HashLink shadow module is
				// still assembled for a Wasm compilation, but never executes this path.
				instructions.push(HlInstruction.LoadInt(defineRegister(output, registers, registerTypes),
					internInt(0)));
			case IrOpcode.PointerOffset:
				if (!folded(output))
					instructions.push(HlInstruction.Call2(defineRegister(output, registers, registerTypes),
						requireFunction("__hl_bytes_offset"), requireRegister(body.operand(row, 0), registers),
						requireRegister(body.operand(row, 1), registers)));
			case IrOpcode.MemoryLoad:
				var size = body.aux(row) >> 1,
					destination = defineRegister(output, registers, registerTypes),
					offset = memoryAddress(body.operand(row, 0), instructions, registers, registerTypes),
					base = memoryBase;
				if (size == 1)
					instructions.push(HlInstruction.GetI8(destination, base, offset));
				else if (size == 2)
					instructions.push(HlInstruction.GetI16(destination, base, offset));
				else
					instructions.push(HlInstruction.GetMem(destination, base, offset));
				if (body.aux(row) & 1 == 1 && size < 4) {
					var shift = temporaryRegister(IrType.I32, registerTypes),
						shiftCount = internInt(size == 1 ? 24 : 16);
					instructions.push(HlInstruction.LoadInt(shift, shiftCount));
					instructions.push(HlInstruction.ShiftLeft(destination, destination, shift));
					instructions.push(HlInstruction.ShiftRight(destination, destination, shift));
				}
			case IrOpcode.MemoryStore:
				var size = body.aux(row),
					offset = memoryAddress(body.operand(row, 0), instructions, registers, registerTypes),
					base = memoryBase,
					value = body.operand(row, 1);
				if (size == 1)
					instructions.push(HlInstruction.SetI8(base, offset, requireRegister(value, registers)));
				else if (size == 2)
					instructions.push(HlInstruction.SetI16(base, offset, requireRegister(value, registers)));
				else
					instructions.push(HlInstruction.SetMem(base, offset, requireRegister(value, registers)));
			case IrOpcode.ConstBool:
				instructions.push(HlInstruction.LoadBool(defineRegister(output, registers, registerTypes),
					body.aux(row) == 1));
			case IrOpcode.ConstNull:
				if (HlLoweringDecisions.isEnumTag(body.valueType(output)))
					instructions.push(HlInstruction.LoadInt(defineRegister(output, registers, registerTypes),
						internInt(HlLoweringDecisions.NULL_ENUM_TAG)));
				else
					instructions.push(HlInstruction.LoadNull(defineRegister(output, registers, registerTypes)));
			case IrOpcode.TypeValue:
				instructions.push(HlInstruction.LoadType(defineRegister(output, registers, registerTypes),
					internType(body.typeOperand(row))));
			case IrOpcode.ToDyn:
				if (!scratch.unboxedArrays.has(output) || firstBinding[output] >= 0)
					instructions.push(HlInstruction.ToDyn(defineRegister(output, registers, registerTypes),
						requireRegister(body.operand(row, 0), registers)));
			case IrOpcode.IntToFloat, IrOpcode.FloatToFloat:
				instructions.push(HlInstruction.ToSFloat(defineRegister(output, registers, registerTypes),
					requireRegister(body.operand(row, 0), registers)));
			case IrOpcode.IntToInt64, IrOpcode.FloatToInt:
				instructions.push(HlInstruction.ToInt(defineRegister(output, registers, registerTypes),
					requireRegister(body.operand(row, 0), registers)));
			case IrOpcode.SafeCast:
				var value = body.operand(row, 0), array = arrayRecasts[output];
				if (array >= 0 && firstBinding[value] < 0)
					instructions.push(HlInstruction.UnsafeCast(defineRegister(output, registers, registerTypes),
						requireRegister(IrValueId.of(array), registers)));
				else if (switch body.valueType(output) {
					case Obj(name): exactTypes.exactType(block, value) == name;
					default: false;
				})
					// A dominating exact-class test proved the value an object of exactly this class.
					instructions.push(HlInstruction.UnsafeCast(defineRegister(output, registers, registerTypes),
					requireRegister(value, registers)));
				else
					instructions.push(HlInstruction.SafeCast(defineRegister(output, registers, registerTypes),
						requireRegister(value, registers)));
			case IrOpcode.BeginTry:
				var catchBlock = body.auxInt(row, 0),
					handlerValue = catchBlock < catchValues.length ? catchValues[catchBlock] : -1;
				if (handlerValue < 0)
					throw new InternalError('Try block $block has no catch value in block $catchBlock');
				instructions.push(HlInstruction.Trap(requireRegister(IrValueId.of(handlerValue), registers), catchBlock,
					body.auxInt(row, 2) == 1));
			case IrOpcode.EndTry:
				var catchBlock = body.auxInt(row, 0),
					handlerValue = catchBlock < catchValues.length ? catchValues[catchBlock] : -1;
				if (handlerValue < 0)
					throw new InternalError('Try block $block ends with unknown handler block $catchBlock');
				instructions.push(HlInstruction.EndTrap(requireRegister(IrValueId.of(handlerValue), registers),
					body.auxInt(row, 1) == 1));
			case IrOpcode.Catch:
			case IrOpcode.GlobalGet:
				var global = requireGlobal(body.symbol(row).name);
				instructions.push(HlInstruction.GlobalGet(defineRegister(output, registers, registerTypes), global));
			case IrOpcode.GlobalSet:
				var global = requireGlobal(body.symbol(row).name);
				instructions.push(HlInstruction.GlobalSet(global, requireRegister(body.operand(row, 0), registers)));
			case IrOpcode.Add, IrOpcode.Sub, IrOpcode.Mul, IrOpcode.Div, IrOpcode.Mod, IrOpcode.BitAnd, IrOpcode.BitXor,
				IrOpcode.BitOr, IrOpcode.ShiftLeft, IrOpcode.ShiftRight, IrOpcode.UnsignedShiftRight:
				var destination = defineRegister(output, registers, registerTypes),
					left = requireRegister(body.operand(row, 0), registers),
					right = requireRegister(body.operand(row, 1), registers);
				instructions.push(switch opcode {
					case IrOpcode.Add: HlInstruction.Add(destination, left, right);
					case IrOpcode.Sub: HlInstruction.Sub(destination, left, right);
					case IrOpcode.Mul: HlInstruction.Mul(destination, left, right);
					case IrOpcode.Div: HlInstruction.Div(destination, left, right);
					case IrOpcode.Mod: HlInstruction.Mod(destination, left, right);
					case IrOpcode.BitAnd: HlInstruction.BitAnd(destination, left, right);
					case IrOpcode.BitXor: HlInstruction.BitXor(destination, left, right);
					case IrOpcode.BitOr: HlInstruction.BitOr(destination, left, right);
					case IrOpcode.ShiftLeft: HlInstruction.ShiftLeft(destination, left, right);
					case IrOpcode.ShiftRight: HlInstruction.ShiftRight(destination, left, right);
					default: HlInstruction.UnsignedShiftRight(destination, left, right);
				});
			case IrOpcode.Less, IrOpcode.LessEqual, IrOpcode.Equal:
				var left = body.operand(row, 0),
					right = body.operand(row, 1),
					operation = opcode == IrOpcode.Less ? 0 : opcode == IrOpcode.LessEqual ? 1 : 2,
					leftNull = operation == 2 && scratch.nullValues[left],
					rightNull = operation == 2 && scratch.nullValues[right];
				if ((output:Int) == fusedCondition) {
					fusedPendingFloat = operation < 2
						&& (isFloat(body.valueType(left)) || isFloat(body.valueType(right)));
					fusedPending = comparisonJump(operation, leftNull, rightNull, requireRegister(left, registers),
						requireRegister(right, registers), -1);
				} else
					lowerComparison(output, left, right, operation, leftNull, rightNull, registers, registerTypes,
						instructions);
			case IrOpcode.EnumDynamicBox, IrOpcode.EnumDynamicView, IrOpcode.EnumTagBox, IrOpcode.EnumTagUnbox,
				IrOpcode.InlineEnumBox, IrOpcode.InlineEnumUnbox:
				throw new InternalError("Unlowered IR intrinsic reached HashLink");
			case IrOpcode.Call:
				lowerCall(row, output, block, fusedCondition, registers, registerTypes, instructions, uses, nonNull,
					firstBinding);
			case IrOpcode.IteratorNew:
				var destination = defineRegister(output, registers, registerTypes),
					boxedArray = temporaryRegister(IrType.Dyn, registerTypes);
				instructions.push(HlInstruction.ToDyn(boxedArray, requireRegister(body.operand(row, 0), registers)));
				instructions.push(HlInstruction.Call1(destination, requireFunction("__iterator_new"), boxedArray));
			case IrOpcode.IteratorHasNext:
				instructions.push(HlInstruction.Call1(defineRegister(output, registers, registerTypes),
					requireFunction("__iterator_has_next"), requireRegister(body.operand(row, 0), registers)));
			case IrOpcode.IteratorNext:
				var destination = defineRegister(output, registers, registerTypes),
					nextNative = HlLoweringDecisions.iteratorNextNative(body.valueType(output));
				if ((switch (nextNative.result) {
					case IrType.Dyn: true;
					default: false;
				})) {
					var dynamicResult = temporaryRegister(IrType.Dyn, registerTypes);
					instructions.push(HlInstruction.Call1(dynamicResult, requireFunction(nextNative.name),
						requireRegister(body.operand(row, 0), registers)));
					instructions.push(HlInstruction.SafeCast(destination, dynamicResult));
				} else
					instructions.push(HlInstruction.Call1(destination, requireFunction(nextNative.name),
						requireRegister(body.operand(row, 0), registers)));
			case IrOpcode.CNativeCall:
				lowerCNativeCall(row, output, registers, registerTypes, instructions);
			case IrOpcode.StaticClosure:
				instructions.push(HlInstruction.StaticClosure(defineRegister(output, registers, registerTypes),
					requireFunction(body.symbol(row).name)));
			case IrOpcode.InstanceClosure:
				instructions.push(HlInstruction.InstanceClosure(defineRegister(output, registers, registerTypes),
					requireFunction(body.symbol(row).name), requireRegister(body.operand(row, 0), registers)));
			case IrOpcode.CallClosure:
				var closure = body.operand(row, 0);
				instructions.push(HlInstruction.NullCheck(requireRegister(closure, registers)));
				if ((switch (body.valueType(closure)) {
					case IrType.Dyn: true;
					default: false;
				})) {
					var callable = temporaryRegister(IrType.Bool, registerTypes),
						error = temporaryRegister(IrType.Bytes, registerTypes),
						valid = freshLabel();
					instructions.push(HlInstruction.Call1(callable, requireFunction("__reflect_is_function"),
						requireRegister(closure, registers)));
					instructions.push(HlInstruction.JumpTrue(callable, valid));
					lowerStringLiteral(error, HlLoweringDecisions.CALL_ERROR, registerTypes, instructions);
					instructions.push(HlInstruction.Throw(error));
					instructions.push(HlInstruction.Label(valid));
				}
				instructions.push(HlInstruction.CallClosure(defineRegister(output, registers, registerTypes),
					requireRegister(closure, registers), operandRegisters(row, 1, registers)));
			case IrOpcode.Upcast:
				// HashLink accepts a subclass register wherever its base class is expected.
				instructions.push(HlInstruction.Move(defineRegister(output, registers, registerTypes),
					requireRegister(body.operand(row, 0), registers)));
			case IrOpcode.ToVirtual:
				instructions.push(HlInstruction.ToVirtual(defineRegister(output, registers, registerTypes),
					requireRegister(body.operand(row, 0), registers)));
			case IrOpcode.MethodCall:
				var object = body.operand(row, 0),
					objectType = body.valueType(object),
					methodName = body.symbol(row).name,
					methodArguments = operandRegisters(row, 0, registers),
					valueMethod = valueMethodFunction(objectType, methodName);
				if (valueMethod == null)
					valueMethod = addedMethodFunction(objectType, methodName);
				if (valueMethod != null) {
					// A value class has no prototype to dispatch through and cannot be subclassed, so its methods are direct calls,
					// as are methods a live patch added.
					var destination = defineRegister(output, registers, registerTypes),
						functionIndex = requireFunction(valueMethod);
					switch methodArguments.length {
						case 1: instructions.push(HlInstruction.Call1(destination, functionIndex, methodArguments[0]));
						case 2: instructions.push(HlInstruction.Call2(destination, functionIndex, methodArguments[0],
							methodArguments[1]));
						default: instructions.push(HlInstruction.CallN(destination, functionIndex, methodArguments));
					}
				} else
					instructions.push(HlInstruction.CallMethod(defineRegister(output, registers, registerTypes),
						requireObjectMethod(objectType, object, methodName), methodArguments));
			case IrOpcode.ValueInit:
				var local = scalarOptionals.get(output);
				if (local != null) {
					for (field in local.declarations) {
						var target:Int = cast local.fields.get(field.name);
						switch field.type {
							case Bool: instructions.push(HlInstruction.LoadBool(target, false));
							case I32, I64: instructions.push(HlInstruction.LoadInt(target, internInt(0)));
							case F32, F64: instructions.push(HlInstruction.LoadFloat(target, internFloat(0.0)));
							default: instructions.push(HlInstruction.LoadNull(target));
						}
					}
				} else
					instructions.push(HlInstruction.New(defineRegister(output, registers, registerTypes),
						requireObjectType(compiler.ir.model.IrTypeTools.valueObjectName(body.valueType(output))), 0));
			case IrOpcode.NewObject:
				instructions.push(HlInstruction.New(defineRegister(output, registers, registerTypes),
					requireObjectType(body.symbol(row).name), 0));
			case IrOpcode.FieldGet:
				lowerFieldGet(row, output, registers, registerTypes, instructions);
			case IrOpcode.FieldSet:
				var object = body.operand(row, 0),
					fieldName = body.symbol(row).name,
					value = body.operand(row, 1),
					local = scalarOptionals.get(object);
				if (local != null) {
					var destination:Int = cast local.fields.get(fieldName);
					instructions.push(HlInstruction.Move(destination, requireRegister(value, registers)));
				} else {
					var objectType = body.valueType(object),
						receiver = requireRegister(object, registers),
						field = requireObjectField(objectType, object, fieldName),
						source = requireRegister(value, registers),
						nativeStorageType = internNativeStorage(body.valueType(value),
							objectFieldNativeLayout(objectType, fieldName));
					if (nativeStorageType != null) {
						var storageSource = temporaryRegisterType(nativeStorageType, registerTypes);
						instructions.push(HlInstruction.ToInt(storageSource, source));
						source = storageSource;
					}
					instructions.push(HlInstruction.FieldSet(receiver, field, source));
				}
			case IrOpcode.ArrayGet:
				var array = body.operand(row, 0), index = body.operand(row, 1);
				instructions.push(HlInstruction.ArrayGet(defineRegister(output, registers, registerTypes),
					requireRegister(array, registers), requireRegister(index, registers)));
				if (rawArrayShift(body.valueType(array)) != null) {
					arrayBounds.prove(array, index);
					arrayBounds.validate(array, index);
				}
			case IrOpcode.ArraySet:
				var array = body.operand(row, 0), index = body.operand(row, 1), value = body.operand(row, 2);
				if (rawArrayShift(body.valueType(array)) != null)
					lowerRawArrayWrite(array, index, requireRegister(value, registers), instructions, registers,
						registerTypes);
				else
					instructions.push(HlInstruction.ArraySet(requireRegister(array, registers),
						requireRegister(index, registers), requireRegister(value, registers)));
			case IrOpcode.ArraySize:
				instructions.push(HlInstruction.ArraySize(defineRegister(output, registers, registerTypes),
					requireRegister(body.operand(row, 0), registers)));
			case IrOpcode.MakeEnum:
				var constructor = body.auxInt(row, 1), outputType = body.valueType(output);
				if (HlLoweringDecisions.isEnumTag(outputType))
					instructions.push(HlInstruction.LoadInt(defineRegister(output, registers, registerTypes),
						internInt(constructor + HlLoweringDecisions.ENUM_TAG_BIAS)));
				else {
					var typeName = body.symbol(row).name,
						destination = defineRegister(output, registers, registerTypes),
						enumConstructor = requireEnumConstructor(typeName, outputType, constructor),
						args = operandRegisters(row, 0, registers);
					if (HlLoweringDecisions.isEnumConstant(body, row))
						lowerEnumConstant(destination, typeName, enumConstructor, instructions);
					else
						instructions.push(HlInstruction.MakeEnum(destination, enumConstructor, args));
				}
			case IrOpcode.EnumIndex:
				var value = body.operand(row, 0);
				if (HlLoweringDecisions.isEnumTag(body.valueType(value))) {
					var bias = temporaryRegister(IrType.I32, registerTypes);
					instructions.push(HlInstruction.LoadInt(bias, internInt(HlLoweringDecisions.ENUM_TAG_BIAS)));
					instructions.push(HlInstruction.Sub(defineRegister(output, registers, registerTypes),
						requireRegister(value, registers), bias));
				} else
					instructions.push(HlInstruction.EnumIndex(defineRegister(output, registers, registerTypes),
						requireRegister(value, registers)));
			case IrOpcode.EnumField:
				instructions.push(HlInstruction.EnumField(defineRegister(output, registers, registerTypes),
					requireRegister(body.operand(row, 0), registers), body.auxInt(row, 0), body.auxInt(row, 1)));
			default:
				throw new InternalError('IR body row $row is not an instruction');
		}
	}

	/** The registers of operands `from` on of `row`, in order. */
	function operandRegisters(row:Int, from:Int, registers:Array<Int>):Array<Int> {
		var body = requireBody();
		return [for (index in from...body.operandCount(row)) requireRegister(body.operand(row, index), registers)];
	}

	function lowerCall(row:Int, output:IrValueId, block:Int, fusedCondition:Int, registers:Array<Int>,
			registerTypes:Array<Int>, instructions:Array<HlInstruction>, uses:Array<Int>,
			nonNull:compiler.ir.model.IrPassScratch.IrValueMarks, firstBinding:Array<Int>):Void {
		var body = requireBody();
		var functionName = body.symbol(row).name, kind = HlLoweringDecisions.classifyCall(functionName);
		if ((output:Int) == fusedCondition) {
			switch kind {
				case ReferenceIdentity:
					// A reference-identity test ending its block: compare the two pointers and jump, with no Bool.
					var pointers = identityPointers(row, instructions, registers, registerTypes);
					fusedPending = comparisonJump(2, false, false, pointers[0], pointers[1], -1);
				case ExactTypeTest:
					// The exact-class test ending its block: compare the object's type pointer and jump, with no Bool.
					var actual = temporaryRegister(IrType.TypeRef, registerTypes);
					instructions.push(HlInstruction.GetType(actual, requireRegister(body.operand(row, 0), registers)));
					var expected = requireRegister(body.operand(row, 1), registers);
					fusedPending = comparisonJump(2, false, false, actual, expected, -1);
				default:
					throw new InternalError('Call of $functionName fused into a branch');
			}
			fusedPendingFloat = false;
			return;
		}
		switch kind {
			case ReceiverCheck:
				// A previous successful dereference or check may already have proved this SSA receiver non-null.
				if (!nonNull.has(row))
					instructions.push(HlInstruction.NullCheck(requireRegister(body.operand(row, 0), registers)));
			case StringLength:
				// The string's `length` read in place, as HashLink reads the field: a null string fails the check, which names
				// the field, unless a dereference before it already proved the string.
				var header = temporaryRegisterType(internRuntimeHeader(BytesHeader), registerTypes);
				instructions.push(HlInstruction.UnsafeCast(header, requireRegister(body.operand(row, 0), registers)));
				if (!nonNull.has(row))
					instructions.push(HlInstruction.NullCheck(header));
				instructions.push(HlInstruction.FieldGet(defineRegister(output, registers, registerTypes), header, 1));
			case ReferenceIdentity:
				var pointers = identityPointers(row, instructions, registers, registerTypes);
				lowerEqualityBool(pointers[0], pointers[1], output, instructions, registers, registerTypes);
			case ExactTypeTest:
				// A plain object of exactly the class: its type pointer equals the class's. Null reads as `void`, a virtual as its own
				// virtual type and a boxed value as its scalar type, so none of them matches an object class.
				var actual = temporaryRegister(IrType.TypeRef, registerTypes);
				instructions.push(HlInstruction.GetType(actual, requireRegister(body.operand(row, 0), registers)));
				lowerEqualityBool(actual, requireRegister(body.operand(row, 1), registers), output, instructions,
					registers,
					registerTypes);
			case WordBits:
				if (body.operandCount(row) != 1 || !compiler.ir.passes.scalars.IrScalarWordBits.valid(functionName,
					body.valueType(body.operand(row, 0)), body.valueType(output)))
					throw new InternalError("Invalid scalar word transport signature");
				var scalar = functionName == compiler.ir.passes.scalars.IrScalarWordBits.PACK
					? body.valueType(body.operand(row, 0)) : body.valueType(output);
				if (compiler.ir.verify.IrVerifier.sameType(scalar, IrType.Abstract("native_callback")))
					throw new InternalError("HashLink callbacks belong in the reference lane");
				instructions.push(HlInstruction.UnsafeCast(defineRegister(output, registers, registerTypes),
					requireRegister(body.operand(row, 0), registers)));
			case LaneReference:
				instructions.push(HlInstruction.UnsafeCast(defineRegister(output, registers, registerTypes),
					requireRegister(body.operand(row, 0), registers)));
			case ScalarRefAddress:
				instructions.push(HlInstruction.Ref(defineRegister(output, registers, registerTypes),
					requireRegister(body.operand(row, 0), registers)));
			case ScalarRefLoad:
				instructions.push(HlInstruction.Unref(defineRegister(output, registers, registerTypes),
					requireRegister(body.operand(row, 0), registers)));
			case ScalarRefStore:
				instructions.push(HlInstruction.Setref(requireRegister(body.operand(row, 0), registers),
					requireRegister(body.operand(row, 1), registers)));
			case ArrayPush, BytesGet, BytesSet:
				lowerRuntimeFastPath(row, output, functionName, kind, instructions, registers, registerTypes);
			case ValueArrayRead:
				var inlineSlot = functionName == HlLoweringDecisions.VALUE_ARRAY_READ_I32
					? HlLoweringDecisions.inlineValueArraySlot(body, row) : null;
				if (uses[output] == 0 && firstBinding[output] < 0
					&& HlLoweringDecisions.usedReadNearby(body, row, uses)) {
					// A field of the element nothing reads; the read beside it checks the element the same way.
				} else if (inlineSlot != null)
					lowerValueArrayRead(row, output, inlineSlot, block, instructions, registers, registerTypes);
				else
					lowerPlainCall(row, output, functionName, instructions, registers, registerTypes);
			case ValueArrayValidate:
				// When a read follows, it checks the same element the same way (`realtime_value_array_check_read`).
				if (!HlLoweringDecisions.scalarReadFollows(body, row))
					lowerPlainCall(row, output, functionName, instructions, registers, registerTypes);
			case Plain:
				lowerPlainCall(row, output, functionName, instructions, registers, registerTypes);
		}
	}

	/** Whether a call of kind `kind` compares two pointers, so that ending its block it can become the branch itself. */
	static function isPointerTest(kind:HlCallKind):Bool
		return switch kind {
			case ExactTypeTest, ReferenceIdentity: true;
			default: false;
		};

	/** Bool `output`: whether registers `left` and `right` are equal. */
	function lowerEqualityBool(left:Int, right:Int, output:IrValueId, instructions:Array<HlInstruction>,
			registers:Array<Int>, registerTypes:Array<Int>):Void {
		var result = defineRegister(output, registers, registerTypes), yes = freshLabel(), done = freshLabel();
		instructions.push(HlInstruction.JumpEqual(left, right, yes));
		instructions.push(HlInstruction.LoadBool(result, false));
		instructions.push(HlInstruction.Jump(done));
		instructions.push(HlInstruction.Label(yes));
		instructions.push(HlInstruction.LoadBool(result, true));
		instructions.push(HlInstruction.Label(done));
	}

	/** A call of function `functionName` with `row`'s operands. */
	function lowerPlainCall(row:Int, output:IrValueId, functionName:String, instructions:Array<HlInstruction>,
			registers:Array<Int>, registerTypes:Array<Int>):Void {
		var body = requireBody();
		var destination = defineRegister(output, registers, registerTypes);
		var functionIndex = requireFunction(functionName);
		var args = operandRegisters(row, 0, registers);
		if (StringTools.startsWith(functionName, "$scalar-closure:receiver:"))
			for (index in 0...args.length)
				switch body.valueType(body.operand(row, index)) {
					case Function(_, _):
						var dynamicClosure = temporaryRegister(IrType.Dyn, registerTypes);
						instructions.push(HlInstruction.ToDyn(dynamicClosure, args[index]));
						args[index] = dynamicClosure;
					default:
				}
		switch args.length {
			case 0: instructions.push(HlInstruction.Call0(destination, functionIndex));
			case 1: instructions.push(HlInstruction.Call1(destination, functionIndex, args[0]));
			case 2: instructions.push(HlInstruction.Call2(destination, functionIndex, args[0], args[1]));
			default: instructions.push(HlInstruction.CallN(destination, functionIndex, args));
		}
	}

	function lowerCNativeCall(row:Int, output:IrValueId, registers:Array<Int>, registerTypes:Array<Int>,
			instructions:Array<HlInstruction>):Void {
		var body = requireBody();
		var functionName = body.symbol(row).name, argumentCount = body.operandCount(row);
		var native = cNatives.get(functionName);
		if (native == null)
			throw new InternalError('Unknown ordinary C function "$functionName"');
		var invocation = HlLoweringDecisions.cNativeInvocation(native, argumentCount);
		var callArguments = [for (_ in 0...3) temporaryRegister(IrType.RawPtr, registerTypes)];
		for (index in 0...3)
			instructions.push(HlInstruction.LoadString(callArguments[index], internString(invocation.strings[index])));
		var resultNullable = invocation.nullable;
		if (resultNullable != null) {
			var ownership = temporaryRegister(IrType.RawPtr, registerTypes),
				release = temporaryRegister(IrType.RawPtr, registerTypes),
				nullable = temporaryRegister(IrType.Bool, registerTypes);
			instructions.push(HlInstruction.LoadString(ownership, internString(invocation.strings[3])));
			instructions.push(HlInstruction.LoadString(release, internString(invocation.strings[4])));
			instructions.push(HlInstruction.LoadBool(nullable, resultNullable));
			callArguments.push(ownership);
			callArguments.push(release);
			if (invocation.strings.length > 5) {
				var length = temporaryRegister(IrType.RawPtr, registerTypes);
				instructions.push(HlInstruction.LoadString(length, internString(invocation.strings[5])));
				callArguments.push(length);
			}
			callArguments.push(nullable);
		}
		for (index in 0...argumentCount) {
			var argument = body.operand(row, index), boxed = temporaryRegister(IrType.Dyn, registerTypes);
			if (scratch.nullValues[argument])
				instructions.push(HlInstruction.LoadNull(boxed));
			else
				instructions.push(HlInstruction.ToDyn(boxed, requireRegister(argument, registers)));
			callArguments.push(boxed);
		}
		var dynamicResult = temporaryRegister(invocation.result, registerTypes);
		instructions.push(HlInstruction.CallN(dynamicResult, requireFunction(invocation.invoker), callArguments));
		if (invocation.isVoid)
			defineRegister(output, registers, registerTypes);
		else if (!invocation.castsResult)
			instructions.push(HlInstruction.Move(defineRegister(output, registers, registerTypes), dynamicResult));
		else
			instructions.push(HlInstruction.SafeCast(defineRegister(output, registers, registerTypes), dynamicResult));
	}

	function lowerFieldGet(row:Int, output:IrValueId, registers:Array<Int>, registerTypes:Array<Int>,
			instructions:Array<HlInstruction>):Void {
		var body = requireBody();
		var object = body.operand(row, 0), fieldName = body.symbol(row).name, local = scratch.scalarLocals.get(object);
		if (local != null) {
			var source:Int = cast local.fields.get(fieldName);
			instructions.push(HlInstruction.Move(defineRegister(output, registers, registerTypes), source));
			return;
		}
		var objectType = body.valueType(object),
			outputType = body.valueType(output),
			destination = defineRegister(output, registers, registerTypes),
			nativeLayout = objectFieldNativeLayout(objectType, fieldName),
			storageType = internNativeStorage(outputType, nativeLayout);
		if ((switch (outputType) {
			case I64: true;
			default: false;
		}) && storageType != null) {
			var stored = temporaryRegisterType(storageType, registerTypes);
			instructions.push(HlInstruction.FieldGet(stored, requireRegister(object, registers),
				requireObjectField(objectType, object, fieldName)));
			instructions.push(HlInstruction.ToInt(destination, stored));
			if (nativeLayout != null && !nativeLayout.signed) {
				var shift = temporaryRegister(IrType.I32, registerTypes);
				instructions.push(HlInstruction.LoadInt(shift, internInt(32)));
				instructions.push(HlInstruction.ShiftLeft(destination, destination, shift));
				instructions.push(HlInstruction.UnsignedShiftRight(destination, destination, shift));
			}
		} else
			instructions.push(HlInstruction.FieldGet(destination, requireRegister(object, registers),
				requireObjectField(objectType, object, fieldName)));
		// Inline records produce an HSTRUCT pointer into their owner. Only scalar
		// narrow fields need sign or zero extension after the field load.
		if (nativeLayout != null && HlLoweringDecisions.extendsNarrowStorage(nativeLayout)) {
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
	}

	/**
	 * Removes the labels no jump or trap names. HashLink needs a label only where control lands by a jump, and every label written is an
	 * instruction the VM compiles at load; a block reached by falling through needs none. Debug locations and the positions of
	 * debug assignments follow the instructions that stay.
	 */
	function dropUnreferencedLabels(instructions:Array<HlInstruction>, debugLocations:Array<HlDebugLocation>,
			assignments:Array<HlDebugAssignment>):Void {
		var referenced = scratch.referencedLabels;
		referenced.clear();
		for (instruction in instructions)
			switch instruction {
				case JumpSignedLessOrEqual(_, _, target), JumpSignedLess(_, _, target), JumpUnsignedLess(_, _, target),
					JumpNull(_, target), JumpEqual(_, _, target), JumpTrue(_, target), Jump(target), Trap(_, target, _),
					JumpFalse(_, target), JumpNotNull(_, target), JumpNotEqual(_, _, target), JumpNotLess(_, _, target),
					JumpNotGreaterOrEqual(_, _, target), JumpSignedGreaterOrEqual(_, _, target),
					JumpSignedGreater(_, _, target),
					JumpUnsignedGreaterOrEqual(_, _, target):
					referenced.add(target);
				case Switch(_, targets):
					for (target in targets)
						referenced.add(target);
				default:
			}
		var located = debugLocations.length == instructions.length, kept = 0, positions = scratch.keptPositions;
		positions.resize(0);
		for (index in 0...instructions.length) {
			positions.push(kept);
			switch instructions[index] {
				case Label(id) if (!referenced.has(id)):
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

	static final generatedDebugLocation:HlDebugLocation = HlDebugLocation.inFile("<generated>", 1, 1, 1, 1, -1, -1, 1);

	// The last location made, and what it was made from: consecutive instructions mostly share their source.
	var lastProvenance:Null<SourceProvenance> = null;

	var lastSource:Null<compiler.ir.model.SourceProvenance.SourceLocation> = null;
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
		var result = new HlDebugLocation(location.anchor, location.line, location.column, location.endLine,
			location.endColumn, location.start, location.end, flags, location.generatedText);
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
	function scopeEndPosition(binding:Int, locations:Array<HlDebugLocation>, position:Int, instructionCount:Int,
			lastByScope:Array<Int>):Int {
		var body = requireBody();
		// Per binding, as a function's assignments of a variable share it: -2 until it is found.
		var lastInScope = lastByScope[binding];
		if (lastInScope == -2) {
			lastInScope = -1;
			// Offsets of one anchor compare as the file's do; a location of another declaration is outside a binding of this one.
			var start = body.bindingScopeStart(binding),
				end = body.bindingScopeEnd(binding),
				anchor = body.bindingAnchor(binding),
				index = locations.length - 1;
			while (index >= 0) {
				var location = locations[index];
				if (location.start >= 0 && location.anchor == anchor && location.start >= start
					&& location.start < end) {
					lastInScope = index;
					break;
				}
				index--;
			}
			lastByScope[binding] = lastInScope;
		}
		var end = (lastInScope >= position ? lastInScope : position) + 1;
		return end >= instructionCount ? -1 : end;
	}

	static function blockProvenance(body:IrBody, block:Int):SourceProvenance {
		var first = body.firstRow(block);
		if (first >= 0)
			return body.provenance(first);
		return SourceProvenance.generated("empty-hl-block");
	}

	/**
		HashLink traps are lexical in the bytecode stream. CFG block identifiers are
		allocation details, so lay each protected region out before its handler and
		its continuation regardless of block creation order.
	**/
	function layOut():Array<Int> {
		var body = requireBody();
		var size = 0;
		for (block in 0...body.blockCount())
			if (body.blockId(block) >= size)
				size = body.blockId(block) + 1;
		var byId = compiler.ir.model.IrPassScratch.filledInts(scratch.blocksById, size, -1), layout = scratch.layout;
		for (block in 0...body.blockCount())
			byId[body.blockId(block)] = block;
		scratch.laidOut.clear();
		layout.resize(0);
		appendReversePostorder(body.blockId(0));
		for (block in 0...body.blockCount())
			if (!scratch.laidOut.has(body.blockId(block)) && body.firstRow(block) >= 0)
				appendReversePostorder(body.blockId(block));
		// A block with neither instructions nor a terminator writes nothing.
		var kept = 0;
		for (block in layout)
			if (body.firstRow(block) >= 0)
				layout[kept++] = block;
		layout.resize(kept);
		var positions = compiler.ir.model.IrPassScratch.filledInts(scratch.layoutPositions, size, -1);
		for (index in 0...kept)
			positions[body.blockId(layout[index])] = index;
		return layout;
	}

	function appendReversePostorder(entry:Int):Void {
		var postorder = scratch.postorder;
		postorder.resize(0);
		visitPostorder(entry);
		var index = postorder.length;
		while (index > 0) {
			index--;
			scratch.layout.push(postorder[index]);
		}
	}

	/**
	 * Depth first from `id` over the blocks not laid out yet. Each block on the walk's stack has a run of children in
	 * `children`, from the end of the run below it to `stackEnd`, of which `stackNext` is the next to visit.
	 */
	function visitPostorder(id:Int):Void {
		var byId = scratch.blocksById, laidOut = scratch.laidOut;
		if (id < 0 || id >= byId.length || byId[id] < 0 || !laidOut.add(id))
			return;
		var stackBlocks = scratch.stackBlocks,
			stackNext = scratch.stackNext,
			stackEnd = scratch.stackEnd,
			children = scratch.children;
		stackBlocks.resize(0);
		stackNext.resize(0);
		stackEnd.resize(0);
		children.resize(0);
		pushPostorder(id);
		while (stackBlocks.length > 0) {
			var top = stackBlocks.length - 1;
			if (stackNext[top] < stackEnd[top]) {
				var child = children[stackNext[top]];
				stackNext[top]++;
				if (child >= 0 && child < byId.length && byId[child] >= 0 && laidOut.add(child))
					pushPostorder(child);
			} else {
				scratch.postorder.push(byId[stackBlocks[top]]);
				children.resize(top > 0 ? stackEnd[top - 1] : 0);
				stackBlocks.pop();
				stackNext.pop();
				stackEnd.pop();
			}
		}
	}

	/** Puts block `id` on the walk's stack, with its children (`visitPostorder`). */
	function pushPostorder(id:Int):Void {
		var body = requireBody();
		var children = scratch.children;
		scratch.stackBlocks.push(id);
		scratch.stackNext.push(children.length);
		appendPostorderChildren(body, scratch.blocksById[id], children);
		scratch.stackEnd.push(children.length);
	}

	static function appendPostorderChildren(body:IrBody, block:Int, children:Array<Int>):Void {
		var catchBlock = -1, afterBlock = -1, terminator = body.terminatorRow(block), row = body.firstRow(block);
		while (row >= 0 && row != terminator) {
			if (body.opcode(row) == IrOpcode.BeginTry) {
				catchBlock = body.auxInt(row, 0);
				afterBlock = body.auxInt(row, 1);
			}
			row = body.nextRow(row);
		}
		if (catchBlock >= 0) {
			// Visit structural exits first because reversal places the protected
			// body before its handler and the handler before the shared exit.
			children.push(afterBlock);
			children.push(catchBlock);
		}
		if (terminator >= 0)
			switch body.opcode(terminator) {
				case IrOpcode.Jump:
					children.push(body.aux(terminator));
				case IrOpcode.Branch:
					children.push(body.auxInt(terminator, 1));
					children.push(body.auxInt(terminator, 0));
				case IrOpcode.Switch:
					// Each successor once, the targets in order and then the default, pushed last first.
					var count = body.successorCount(terminator), index = count;
					while (index > 0) {
						index--;
						var target = body.successor(terminator, index), first = true;
						for (earlier in 0...index)
							if (body.successor(terminator, earlier) == target)
								first = false;
						if (first)
							children.push(target);
					}
				default:
			}
	}

	/**
	 * Groups the phi moves of `fn` by the block their edge leaves, in the order of the phis and of their inputs. Only an edge
	 * that is a jump can carry moves; a block whose moves go to more than one block has the target -2.
	 */
	function groupPhiMoves():Void {
		var body = requireBody();
		var size = 0, total = 0;
		for (block in 0...body.blockCount()) {
			if (body.blockId(block) >= size)
				size = body.blockId(block) + 1;
			var row = body.firstRow(block);
			while (row >= 0) {
				if (body.opcode(row) == IrOpcode.Phi)
					for (input in 0...body.operandCount(row))
						if (body.auxInt(row, input) >= size)
							size = body.auxInt(row, input) + 1;
				row = body.nextRow(row);
			}
		}
		var starts = compiler.ir.model.IrPassScratch.filledInts(scratch.moveStart, size, 0),
			counts = compiler.ir.model.IrPassScratch.filledInts(scratch.moveCount, size, 0),
			targets = compiler.ir.model.IrPassScratch.filledInts(scratch.moveTarget, size, -1);
		for (block in 0...body.blockCount()) {
			var id = body.blockId(block), row = body.firstRow(block);
			while (row >= 0) {
				if (body.opcode(row) == IrOpcode.Phi)
					for (input in 0...body.operandCount(row)) {
						var from = body.auxInt(row, input);
						counts[from]++;
						total++;
						var target = targets[from];
						targets[from] = target == -1 || target == id ? id : -2;
					}
				row = body.nextRow(row);
			}
		}
		var offset = 0;
		for (id in 0...size) {
			starts[id] = offset;
			offset += counts[id];
			counts[id] = 0;
		}
		var destinations = compiler.ir.model.IrPassScratch.filledInts(scratch.moveDestinations, total, -1),
			sources = compiler.ir.model.IrPassScratch.filledInts(scratch.moveSources, total, -1);
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				if (body.opcode(row) == IrOpcode.Phi)
					for (input in 0...body.operandCount(row)) {
						var from = body.auxInt(row, input), at = starts[from] + counts[from];
						destinations[at] = body.output(row);
						sources[at] = body.operand(row, input);
						counts[from]++;
					}
				row = body.nextRow(row);
			}
		}
	}

	/** Whether the edge `from` to `to` has phi moves. */
	function hasPhiMoves(from:Int, to:Int):Bool {
		if (from < 0 || from >= scratch.moveCount.length || scratch.moveCount[from] == 0)
			return false;
		var target = scratch.moveTarget[from];
		return target == to || target == -2;
	}

	/**
	 * Writes the phi moves of the jump leaving `from`, which happen at once; `scratch.writtenValues` and `writtenPositions` are
	 * then the values written and where.
	 */
	function emitPhiMoves(from:Int, registers:Array<Int>, registerTypes:Array<Int>,
			instructions:Array<HlInstruction>):Void {
		if (scratch.moveTarget[from] == -2)
			throw new InternalError("Phi elimination requires split critical edges");
		var writtenValues = scratch.writtenValues,
			writtenPositions = scratch.writtenPositions,
			destinations = scratch.moveDestinations,
			sources = scratch.moveSources,
			start = scratch.moveStart[from],
			count = scratch.moveCount[from];
		writtenValues.resize(0);
		writtenPositions.resize(0);
		if (count == 1) {
			var destination = requireRegister(IrValueId.of(destinations[start]), registers),
				source = requireRegister(IrValueId.of(sources[start]), registers);
			if (destination != source) {
				writtenValues.push(destinations[start]);
				writtenPositions.push(instructions.length);
				instructions.push(HlInstruction.Move(destination, source));
			}
			return;
		}
		// A move is written once no move still to be written reads its destination, and a cycle of moves is broken by saving
		// one destination in a temporary and reading that instead.
		var pendingDestinations = scratch.pendingDestinations,
			pendingSources = scratch.pendingSources,
			pendingValues = scratch.pendingValues;
		pendingDestinations.resize(0);
		pendingSources.resize(0);
		pendingValues.resize(0);
		for (index in start...start + count) {
			var destination = requireRegister(IrValueId.of(destinations[index]), registers),
				source = requireRegister(IrValueId.of(sources[index]), registers);
			if (destination != source) {
				pendingDestinations.push(destination);
				pendingSources.push(source);
				pendingValues.push(destinations[index]);
			}
		}
		while (pendingDestinations.length > 0) {
			var ready = -1;
			for (index in 0...pendingDestinations.length) {
				var read = false;
				for (other in 0...pendingSources.length)
					if (pendingSources[other] == pendingDestinations[index]) {
						read = true;
						break;
					}
				if (!read) {
					ready = index;
					break;
				}
			}
			if (ready < 0) {
				var saved = pendingDestinations[0],
					temporary = temporaryRegisterType(registerTypes[saved], registerTypes);
				instructions.push(HlInstruction.Move(temporary, saved));
				for (index in 0...pendingSources.length)
					if (pendingSources[index] == saved)
						pendingSources[index] = temporary;
				continue;
			}
			var destination = pendingDestinations[ready], source = pendingSources[ready];
			writtenValues.push(pendingValues[ready]);
			writtenPositions.push(instructions.length);
			instructions.push(HlInstruction.Move(destination, source));
			for (index in ready...pendingDestinations.length - 1) {
				pendingDestinations[index] = pendingDestinations[index + 1];
				pendingSources[index] = pendingSources[index + 1];
				pendingValues[index] = pendingValues[index + 1];
			}
			pendingDestinations.pop();
			pendingSources.pop();
			pendingValues.pop();
		}
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

	function lowerComparison(output:IrValueId, left:IrValueId, right:IrValueId, operation:Int, leftNull:Bool,
			rightNull:Bool, registers:Array<Int>, registerTypes:Array<Int>, instructions:Array<HlInstruction>):Void {
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

	/**
	 * The pointer offsets of `fn` read only as the address of loads and stores, by output id. HashLink's memory opcodes take a
	 * byte offset register, so such an address is never made: each access takes the offset's pointer and byte offset itself.
	 * `uses` counts every read of a value; a debug binding keeps the offset, so a debugger can show it.
	 */
	function foldPointerOffsets(uses:Array<Int>):Void {
		var body = requireBody();
		var limit = body.valueLimit(),
			pointers = compiler.ir.model.IrPassScratch.filledInts(scratch.foldedPointers, limit, -1),
			offsets = compiler.ir.model.IrPassScratch.filledInts(scratch.foldedOffsets, limit, -1),
			addressUses = compiler.ir.model.IrPassScratch.filledInts(scratch.addressUses, limit, 0);
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				switch body.opcode(row) {
					case IrOpcode.PointerOffset:
						pointers[body.output(row)] = body.operand(row, 0);
						offsets[body.output(row)] = body.operand(row, 1);
					case IrOpcode.MemoryLoad, IrOpcode.MemoryStore:
						addressUses[body.operand(row, 0)]++;
					default:
				}
				row = body.nextRow(row);
			}
		}
		for (index in 0...body.bindingCount())
			pointers[body.bindingValue(index)] = -1;
		var any = false;
		for (id in 0...limit)
			if (pointers[id] >= 0) {
				if (addressUses[id] == 0 || addressUses[id] != uses[id])
					pointers[id] = -1;
				else
					any = true;
			}
		hasFoldedAddresses = any;
	}

	/** Whether pointer offset `value` is folded into the loads and stores that read it (`foldPointerOffsets`). */
	inline function folded(value:IrValueId):Bool
		return hasFoldedAddresses && scratch.foldedPointers[value] >= 0;

	/**
	 * The byte offset register of the address `pointer` for a memory access, with its base register in `memoryBase`: a folded
	 * offset's pointer and byte offset, or `pointer` itself at a zero offset.
	 */
	function memoryAddress(pointer:IrValueId, instructions:Array<HlInstruction>, registers:Array<Int>,
			registerTypes:Array<Int>):Int {
		if (folded(pointer)) {
			memoryBase = requireRegister(IrValueId.of(scratch.foldedPointers[pointer]), registers);
			return requireRegister(IrValueId.of(scratch.foldedOffsets[pointer]), registers);
		}
		var zeroOffset = temporaryRegister(IrType.I32, registerTypes);
		instructions.push(HlInstruction.LoadInt(zeroOffset, internInt(0)));
		memoryBase = requireRegister(pointer, registers);
		return zeroOffset;
	}

	/** Whether the function being lowered has folded pointer offsets, and the base register `memoryAddress` gave last. */
	var hasFoldedAddresses = false;

	var memoryBase = 0;

	function defineRegister(value:IrValueId, registers:Array<Int>, types:Array<Int>):Int {
		var body = requireBody();
		if (registers[value] >= 0)
			return registers[value];
		var index = types.length;
		registers[value] = index;
		types.push(internTypeId(body.valueTypeId(value)));
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

	/** The array bounds proved and validated in the block being lowered, and the loops' proofs of the function. */
	final arrayBounds:HlArrayBounds;

	/**
	 * The byte-offset register of every array and index pair accessed so far in the block being lowered, by its number
	 * (`HlArrayBounds.pair`). The offset depends only on the index, so it stays valid however much code runs in between.
	 * Read validation is recorded separately, since fused reads no longer need an offset register.
	 */
	final elementOffsets:Map<Int, Int> = [];

	/** The value array each array value's header leads to, resolved in the block being lowered (`valueArrayView`). */
	final valueArrayViews:Map<Int, ValueArrayView> = [];

	/** The array values of the function being lowered that have inline reads, and their views resolved where defined. */
	final viewedArrays:Map<Int, Bool> = [];

	final definedViews:Map<Int, ValueArrayView> = [];

	var hasViewedArrays = false;

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
	function lowerRawArrayWrite(array:IrValueId, index:IrValueId, source:Int, instructions:Array<HlInstruction>,
			registers:Array<Int>, registerTypes:Array<Int>):Void {
		var body = requireBody();
		var arrayType = body.valueType(array), elementShift = rawArrayShift(arrayType);
		if (elementShift == null)
			throw new InternalError("Inline array access requires an Int or Float array");
		var arrayRegister = requireRegister(array, registers),
			indexRegister = requireRegister(index, registers);
		if (!arrayBounds.isProven(array, index) && !arrayBounds.isValidated(array, index)) {
			var outOfRange = freshLabel(),
				inRange = freshLabel(),
				size = temporaryRegister(IrType.I32, registerTypes),
				unused = temporaryRegister(IrType.Void, registerTypes);
			instructions.push(HlInstruction.ArraySize(size, arrayRegister));
			instructions.push(HlInstruction.JumpUnsignedLess(indexRegister, size, inRange));
			instructions.push(HlInstruction.Label(outOfRange));
			instructions.push(HlInstruction.Call2(unused, requireFunction(rawArrayNativeName(arrayType, "ensure")),
				arrayRegister, indexRegister));
			instructions.push(HlInstruction.Label(inRange));
			arrayBounds.prove(array, index);
		}
		arrayBounds.validate(array, index);
		var key = arrayBounds.pair(array, index), offset = elementOffsets.get(key);
		if (offset == null) {
			var shift = temporaryRegister(IrType.I32, registerTypes);
			offset = temporaryRegister(IrType.I32, registerTypes);
			instructions.push(HlInstruction.LoadInt(shift, internInt(elementShift)));
			instructions.push(HlInstruction.ShiftLeft(offset, indexRegister, shift));
			elementOffsets.set(key, offset);
		}
		var data = temporaryRegister(IrType.Bytes, registerTypes);
		instructions.push(HlInstruction.RefData(data, arrayRegister));
		instructions.push(HlInstruction.SetMem(data, offset, source));
	}

	/** The two references a reference-identity test compares, as raw pointers: a virtual is compared by the object it wraps. */
	function identityPointers(row:Int, instructions:Array<HlInstruction>, registers:Array<Int>,
			registerTypes:Array<Int>):Array<Int> {
		var body = requireBody();
		var pointers:Array<Int> = [];
		for (index in 0...body.operandCount(row)) {
			var argument = body.operand(row, index), source = requireRegister(argument, registers);
			switch body.valueType(argument) {
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

	/** An array push or byte read or write: the common case inline, the native on the slow path. */
	function lowerRuntimeFastPath(row:Int, output:IrValueId, name:String, kind:HlCallKind,
			instructions:Array<HlInstruction>, registers:Array<Int>, registerTypes:Array<Int>):Void {
		var body = requireBody();
		var push = kind == ArrayPush, get = kind == BytesGet;
		var destination = defineRegister(output, registers, registerTypes);
		var args = operandRegisters(row, 0, registers);
		var slow = freshLabel(),
			done = freshLabel();
		var size = temporaryRegister(IrType.I32, registerTypes);
		// The array was checked before the row (`HlLoweringDecisions.receiverOf`); null bytes take the native.
		if (!push)
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
			var slot = temporaryRegisterType(internReference(body.valueType(body.operand(row, 1))), registerTypes);
			instructions.push(HlInstruction.RefData(data, args[0]));
			instructions.push(HlInstruction.UnsafeCast(slot, data));
			instructions.push(HlInstruction.RefOffset(slot, slot, size));
			instructions.push(HlInstruction.Setref(slot, args[1]));
		} else {
			var data = temporaryRegister(IrType.RawPtr, registerTypes);
			instructions.push(HlInstruction.FieldGet(size, header, 1));
			instructions.push(HlInstruction.JumpUnsignedGreaterOrEqual(args[1], size, slow));
			instructions.push(HlInstruction.FieldGet(data, header, 0));
			if (get)
				instructions.push(HlInstruction.GetI8(destination, data, args[1]));
			else {
				instructions.push(HlInstruction.SetI8(data, args[1], args[2]));
				instructions.push(HlInstruction.LoadBool(destination, true));
			}
		}
		instructions.push(HlInstruction.Jump(done));
		instructions.push(HlInstruction.Label(slow));
		if (args.length == 2)
			instructions.push(HlInstruction.Call2(destination, requireFunction(name), args[0], args[1]));
		else
			instructions.push(HlInstruction.CallN(destination, requireFunction(name), args));
		instructions.push(HlInstruction.Label(done));
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

	function requireRegister(value:IrValueId, registers:Array<Int>):Int {
		var register = (value:Int) >= 0 && (value:Int) < registers.length ? registers[value] : -1;
		if (register < 0)
			throw new InternalError('IR value ${(value : Int)} is used before definition');
		return register;
	}

	// Everything below that asks the symbol tables or the function layout for an index also notes the question and the answer, when
	// the function being lowered is recorded: those requests are what lets another build give the function other indices.
	function internInt(value:Int):Int {
		var index = symbols.internInt(value);
		if (recordedKeys != null)
			record(ConstInt(value, index));
		return index;
	}

	function internFloat(value:Float):Int {
		var index = symbols.internFloat(value);
		if (recordedKeys != null)
			record(ConstFloat(value, index));
		return index;
	}

	function internString(value:String):Int {
		var index = symbols.internString(value);
		if (recordedKeys != null)
			record(ConstString(value, index));
		return index;
	}

	function internType(type:IrType):Int
		return internTypeId(IrTypeIds.id(type));

	/**
	 * `internType` of the type with id `id`. The symbol table and the request numbers keep both answers by id, so a register's type
	 * is two array reads.
	 */
	function internTypeId(id:Int):Int {
		var index = symbols.internTypeId(id), keys = recordedKeys;
		if (keys != null)
			requestKeys.recordType(id, index, keys, recordedAnswers);
		return index;
	}

	function internFunctionType(arguments:Array<IrType>, result:IrType):Int
		return internType(IrType.Function(arguments, result));

	function internReference(type:IrType):Int {
		var id = IrTypeIds.id(type), index = symbols.internReferenceId(id);
		if (recordedKeys != null)
			record(RefTo(id, index));
		return index;
	}

	/** An object type laid out like the runtime header `kind` (`HlSymbolTable.internRuntimeHeader`). */
	function internRuntimeHeader(kind:HlRuntimeHeader):Int {
		var index = symbols.internRuntimeHeader(kind);
		if (recordedKeys != null)
			record(RuntimeHeader(kind, index));
		return index;
	}

	function internNativeStorage(type:IrType, layout:Null<compiler.ir.model.Ir.IrScalarStorage>):Null<Int> {
		var index = symbols.internNativeFieldStorageType(type, layout);
		if (recordedKeys != null && layout != null)
			record(NativeStorage(type, layout, index));
		return index;
	}

	function internGlobalSlot(name:String, type:IrType):Int {
		var index = symbols.internGlobal(name, type);
		if (recordedKeys != null)
			record(GlobalSlot(name, type, index));
		return index;
	}

	function requireGlobal(name:String):Int {
		var index = symbols.requireGlobalIndex(name);
		if (recordedKeys != null)
			record(GlobalByName(name, index));
		return index;
	}

	function internStringLiteral(value:String):Int {
		var index = symbols.internStringConstant(value);
		if (recordedKeys != null)
			record(StringLiteral(value, index));
		return index;
	}

	function internEnumValue(enumName:String, constructor:Int):Int {
		var index = symbols.internEnumConstant(enumName, constructor);
		if (recordedKeys != null)
			record(EnumValue(enumName, constructor, index));
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
		var keys = recordedKeys;
		if (keys != null)
			requestKeys.recordType(IrTypeIds.id(IrType.Obj(name)), index, keys, recordedAnswers);
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
						case Object(baseName, _, _, _, _, _): symbols.string(baseName);
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

	function requireObjectField(objectType:IrType, object:IrValueId, name:String):Int {
		var typeName = switch objectType {
			case Obj(value): value;
			default: throw new InternalError('IR value ${(object : Int)} is not an object');
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
			if (recordedKeys != null)
				record(FieldSlot(cached.owner, name, cached.index));
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
					if (recordedKeys != null)
						record(FieldSlot(published.owner, name, published.index));
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
		if (recordedKeys != null)
			record(FieldSlot(owner, name, resolved));
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

	function objectFieldNativeLayout(objectType:IrType, name:String):Null<compiler.ir.model.Ir.IrScalarStorage> {
		var typeName = switch objectType {
			case Obj(value): value;
			default: return null;
		};
		return objectFieldNativeLayoutForType(typeName, name);
	}

	function objectFieldNativeLayoutForType(typeName:String, name:String):Null<compiler.ir.model.Ir.IrScalarStorage> {
		var descriptor = view.object(typeName);
		if (descriptor == null)
			return null;
		for (field in descriptor.fields)
			if (field.name == name)
				return compiler.ir.model.IrFieldStorage.scalar(field);
		return descriptor.base == null ? null : objectFieldNativeLayoutForType(Std.string(descriptor.base), name);
	}

	/** The implementing function of `name` when `value` is an instance of a value class, whose methods are not virtual. */
	function valueMethodFunction(valueType:IrType, name:String):Null<String> {
		var typeName = switch valueType {
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
	function addedMethodFunction(valueType:IrType, name:String):Null<String> {
		var typeName = switch valueType {
			case Obj(objectName): objectName;
			default: return null;
		};
		var slots = symbols.objectMethodSlots(typeName);
		if (recordedKeys != null)
			record(MethodSlotKnown(typeName, name, HlRemap.methodSlotAnswer(symbols, typeName, name)));
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

	function requireObjectMethod(valueType:IrType, value:IrValueId, name:String):Int {
		var typeName = switch valueType {
			case Obj(value): value;
			case Virtual(value):
				var slot = symbols.requireInterfaceMethodIndex(value, name);
				if (recordedKeys != null)
					record(InterfaceSlot(value, name, slot));
				return slot;
			default: throw new InternalError('IR value ${(value : Int)} is not an object');
		};
		var slot = symbols.requireObjectMethodIndex(typeName, name);
		if (recordedKeys != null)
			record(MethodSlot(typeName, name, slot));
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
		return name == StdlibNames.EQUATABLE || name == StdlibNames.HASHABLE || name == StdlibNames.DIFFABLE;

	function closeInterfaces(names:Array<String>):Array<String> {
		var result:Array<String> = [], seen:Map<String, Bool> = [];
		function visit(name:String):Void {
			if (seen.exists(name))
				return;
			seen.set(name, true);
			result.push(name);
			var bases = interfaceBases.get(name);
			if (bases != null)
				for (base in bases)
					visit(base);
		}
		for (name in names)
			visit(name);
		return result;
	}

	/** Records `request` of the function being lowered, when lowering records them. */
	function record(request:HlSymbolRequest):Void {
		var keys = recordedKeys;
		if (keys != null)
			requestKeys.record(request, keys, recordedAnswers);
	}

	function addFunctionName(name:String, index:Int):Void {
		if (functionIndices.exists(name))
			throw new InternalError('Duplicate IR function "$name"');
		functionIndices.set(name, index);
	}

	function requireFunction(name:String):Int {
		var index = functionIndices.get(name);
		if (index == null)
			throw new InternalError('Unknown IR function "$name"');
		if (recordedKeys != null)
			record(FunctionRef(name, index));
		return index;
	}
}

/** A value array as raw memory (null for a header that is no value array's) and its stride in bytes. */
private typedef ValueArrayView = {
	final array:Int;
	final strideBytes:Int;
}
