package compiler.ir;

import compiler.core.InternalError;
import haxe.io.Bytes;
import compiler.ir.IrStaticNullChecks.IrStaticCheckCache;
import compiler.ir.Ir;
import compiler.ir.IrFunction;
import compiler.ir.SourceProvenance;
import compiler.ir.SourceProvenance.Located;
import compiler.ir.codec.IrFunctionStateCodec;

/** An inlined function together with everything its result depended on. */
class InlineMemo {
	public final source:IrFunction;

	/** Which fingerprint of the program-wide settings (see `IrInlineCache.fingerprintId`) the result was inlined under. */
	public final fingerprint:Int;

	/** The pristine callee functions consulted, transitively; the result is valid only while all are unchanged. */
	public final dependencies:Array<IrFunction>;

	/**
	 * The objects consulted, transitively, each with the print (see `IrInlineCache.objectPrintId`) it had; the result is valid
	 * only while every one of them still has it.
	 */
	public final objects:Map<String, Int>;

	/** The inlined form, frozen. */
	public final result:IrBody;

	public function new(source:IrFunction, fingerprint:Int, dependencies:Array<IrFunction>, objects:Map<String, Int>,
			result:IrBody) {
		this.source = source;
		this.fingerprint = fingerprint;
		this.dependencies = dependencies;
		this.objects = objects;
		this.result = result;
	}
}

/**
 * Per-session inliner state. `memo` keeps a function's inlined form while it and every callee it looked at are
 * unchanged, so unchanged functions keep their identity between compiles; `published` is the inlined form each
 * function had after the last successful compile, which is what a patch has to be computed against.
 */
class IrInlineCache {
	public var memo:Map<String, InlineMemo> = [];
	public var published:Map<String, IrFunction> = [];

	/**
	 * Final cleanup depends only on the inliner's result and must not affect inlining decisions: each function's cleaned form,
	 * decoded, kept while its inlined form is the same body.
	 */
	public var cleaned:Map<String, {source:IrBody, result:IrFunction}> = [];

	/** The type ids every body the inliner keeps is made with, for the session. */
	public var types(default, null) = new IrTypeIds();

	/** Each function's source as a frozen body, kept while the source is the same object, so it is encoded once. */
	public var originals:Map<String, {source:IrFunction, body:IrBody}> = [];

	/**
	 * The encoding of a published function, kept with the function it belongs to (null when it cannot be encoded). Comparing a
	 * re-inlined function with the published one then encodes only the new one, and a published function is encoded once.
	 */
	public var publishedBytes:Map<String, {fn:IrFunction, bytes:Null<Bytes>}> = [];

	/** The static-null-check copies of the program's functions, so they keep their identity between compiles. */
	public final staticChecks:IrStaticCheckCache = new IrStaticCheckCache();

	/** Each function's instrumented form, kept while its inlined form and the scope are unchanged. */
	public var instrumented:Map<String, {source:IrFunction, scope:String, result:IrFunction}> = [];

	/** Functions the last run found unchanged except for where they sit in their file: lowered again, never patched. */
	public var relocated:Array<String> = [];

	/**
	 * Code fingerprints of the positionally named functions (lambdas), by the function they were taken from: an unchanged
	 * module keeps its IR functions between compiles, so its ~100 ms of re-encoding and hashing per compile is skipped.
	 * Assembly rewrites calls to C natives inside the functions, so a different set of C natives starts over.
	 */
	var positionalPrints:Map<String, {fn:IrFunction, print:String}> = [];

	var nextPositionalPrints:Map<String, {fn:IrFunction, print:String}> = [];
	var positionalNatives:Null<String> = null;

	/** `IrFunctionStateCodec.codeFingerprint(fn)`, remembered while `fn` and the program's C natives stay the same. */
	public function positionalFingerprint(fn:IrFunction, cNatives:String):String {
		if (positionalNatives != cNatives) {
			positionalPrints = [];
			positionalNatives = cNatives;
		}
		var known = positionalPrints.get(fn.name);
		if (known == null || known.fn != fn)
			known = {fn: fn, print: IrFunctionStateCodec.codeFingerprint(fn)};
		nextPositionalPrints.set(fn.name, known);
		return known.print;
	}

	/** Keeps only the fingerprints this compile asked for, so a removed function's entry does not stay alive. */
	public function finishPositionalFingerprints():Void {
		positionalPrints = nextPositionalPrints;
		nextPositionalPrints = [];
	}

	var lastFingerprint:Null<String> = null;
	var lastFingerprintId = 0;
	var objectTexts:Map<String, String> = [];
	var objectIds:Map<String, Int> = [];
	var lastObjectId = 0;

	public function new() {}

	/**
	 * A number that names a program-wide fingerprint: the same while the fingerprint text is unchanged, a new one when it
	 * changes. A memo entry is checked against it for every function of the program on every compile, which as a
	 * comparison of the (large, freshly built) text cost a third of an incremental compile.
	 */
	public function fingerprintId(text:String):Int {
		if (lastFingerprint == null || lastFingerprint != text) {
			lastFingerprint = text;
			lastFingerprintId++;
		}
		return lastFingerprintId;
	}

	/**
	 * A number that names what an object's description said: the same while the description is unchanged, a new one when
	 * it changes. An object that does not exist is described by null. A memo entry records the number of each object its
	 * result depended on, so a new class or a changed method table invalidates only the functions that looked at it.
	 */
	public function objectPrintId(name:String, text:Null<String>):Int {
		var known = objectTexts.exists(name);
		if (!known || objectTexts.get(name) != text) {
			objectTexts.set(name, text);
			objectIds.set(name, ++lastObjectId);
		}
		var id = objectIds.get(name);
		return id == null ? 0 : id;
	}

	/** Representation passes can rebuild identical immutable inputs. Compare their complete state without
	 * materializing serialized graphs; hashes and debug placement still participate, and unknown data never matches.
	 * Each run replaces the map, so transaction copies share only immutable entries and removed names are pruned.
	 */
	var sources:Map<String, IrFunction> = [];

	/**
	 * The same for the functions where the pipeline starts reading bodies (docs/design/IR_CORE_COLUMNS.md, the conversion point):
	 * a function rebuilt the same as last time is then the object that has its body already, so it is not encoded again.
	 */
	var bodySources:Map<String, IrFunction> = [];

	public function stableSources(functions:Array<IrFunction>):Array<IrFunction> {
		var next:Map<String, IrFunction> = [], result = stable(functions, sources, next);
		sources = next;
		return result;
	}

	public function stableBodySources(functions:Array<IrFunction>):Array<IrFunction> {
		var next:Map<String, IrFunction> = [], result = stable(functions, bodySources, next);
		bodySources = next;
		return result;
	}

	static function stable(functions:Array<IrFunction>, previous:Map<String, IrFunction>,
			next:Map<String, IrFunction>):Array<IrFunction> {
		var result:Array<IrFunction> = [];
		for (fn in functions) {
			var known = previous.get(fn.name);
			if (known == null || !compiler.ir.codec.IrFunctionStateEquality.same(known, fn))
				known = fn;
			next.set(fn.name, known);
			result.push(known);
		}
		return result;
	}

	/** Lets the sources go, for a compile no next one reuses: they are the objects the stage's bodies were made from. */
	public function forgetSources():Void {
		sources = [];
		bodySources = [];
		staticChecks.copies = [];
		staticChecks.helpers = [];
	}

	public function copy():IrInlineCache {
		var result = new IrInlineCache();
		result.sources = sources;
		result.bodySources = bodySources;
		result.types = types;
		for (name => entry in originals)
			result.originals.set(name, entry);
		for (name => entry in memo)
			result.memo.set(name, entry);
		for (name => fn in published)
			result.published.set(name, fn);
		for (name => entry in cleaned)
			result.cleaned.set(name, entry);
		for (name => entry in publishedBytes)
			result.publishedBytes.set(name, entry);
		for (name => entry in instrumented)
			result.instrumented.set(name, {source: entry.source, scope: entry.scope, result: entry.result});
		result.staticChecks.copies = staticChecks.copies;
		result.staticChecks.helpers = staticChecks.helpers;
		result.staticChecks.valueShape = staticChecks.valueShape;
		for (name => entry in positionalPrints)
			result.positionalPrints.set(name, entry);
		result.positionalNatives = positionalNatives;
		result.lastFingerprint = lastFingerprint;
		result.lastFingerprintId = lastFingerprintId;
		for (name => text in objectTexts)
			result.objectTexts.set(name, text);
		for (name => id in objectIds)
			result.objectIds.set(name, id);
		result.lastObjectId = lastObjectId;
		return result;
	}
}

/**
 * Inlines small callees into their callers. See docs/design/INLINING_AND_VALUE_TYPES.md.
 *
 * The pass never mutates a function it was given: cached IR is shared between compiles and transaction snapshots, so a
 * caller that changes is rebuilt as a new IrFunction and unchanged callers keep their identity. Decisions depend only
 * on IR content and on the (sorted) order of `program.functions`, so an incremental build matches a clean one.
 */
class IrInliner {
	/** Instruction budget for a callee without an `inline` hint. */
	public static inline var SmallBudget = 24;

	/** Instruction budget for a callee declared `inline`. */
	public static inline var HintBudget = 96;

	static inline var MaxBlocks = 12;
	static inline var MaxInlinesPerFunction = 48;
	static inline var MaxFunctionInstructions = 3000;
	static inline var MaxChainDepth = 24;

	final profile:TargetProfile;

	final byName:Map<String, IrFunction> = [];

	/**
	 * Every function has a number, assigned once in name order, and the per-function state below is indexed by it: a callee name is
	 * hashed once per call instruction, and nothing after that hashes a string. Sorting numbers is sorting names.
	 */
	final ids:Map<String, Int> = [];

	/** The function id of each call target by `IrSymbol.id`, -1 for a symbol that names no function here. */
	final idsBySymbol:Array<Int> = [];

	final functions:Array<IrFunction> = [];
	final done:Array<Null<IrBody>> = [];

	/** The type ids of every body of this run: the cache's. */
	final types:IrTypeIds;

	final voidType:Int;
	final receiverCheckSymbol:Int;

	/** By function id, its inlined form when that is its source's encoding, unchanged, else null. */
	final sourceBodies:Array<Null<IrBody>> = [];

	/** By function id, its source body as copy elision reads it, in a compile that keeps no session (else `IrInlineCache.originals`). */
	final pristine:Array<Null<IrBody>> = [];

	/**
	 * By function id, its cleaned-up form when the inlining that made its memoized form ran in this compile: the cleanup edits the
	 * body the inlining did, which no cache holds, once the memo has its own compacted copy.
	 */
	final cleanedForms:Array<Null<IrFunction>> = [];

	/** By function id, the instructions of its source body, for the screen of what may be inlined after the body is edited. */
	final sourceSizes:Array<Int> = [];

	/**
	 * Whether the functions' inlining edits their source bodies in place: in a compile that keeps no session, when no source has a
	 * value copy, so copy elision, which reads callees' source bodies, never runs; else each is edited on a copy.
	 */
	var ownsSources = false;

	/** The tables of one splice or expansion: by callee value id its value here, by callee block id its block id here. */
	final calleeValues:Array<Int> = [];

	final calleeBlocks:Array<Int> = [];

	/** The rows an inlined call puts before the callee's (receiver check, upcasts), or a splice puts in place of the call. */
	final madeRows:Array<Int> = [];

	final successorIds:Array<Int> = [];
	final returnedValues:Array<Int> = [];
	final returnedBlocks:Array<Int> = [];

	/** Copy elision's callbacks, made once. */
	final bodyLookup:String->Null<IrBody>;

	final methodLookup:IrType->String->Null<String>;
	final consultLookup:String->Void;
	final dependenciesOf:Array<Null<Array<IrFunction>>> = [];
	final dependencyIdsOf:Array<Null<Array<Int>>> = [];
	final impure:Array<Bool> = [];
	final visiting:Array<Bool> = [];
	final entryPoint:String;

	/** The program's objects and the direct subclasses of each (for resolving a virtual call when every override agrees). */
	/** The most classes a method call's resolution looks at: the receiver's class and the classes that extend it. */
	static inline final MaxSubclassWalk = 256;

	final table:IrObjectTable;

	/** The tables the cleanup passes reuse across functions. */
	final passScratch = new IrPassScratch();

	/** Which function each class and method resolve to, shared with the other passes that resolve calls. */
	final resolution:IrMethodResolution;

	/** The print of every object of the program, by name. */
	final objectPrints:Map<String, Int> = [];

	final cache:IrInlineCache;
	final allowInline:Bool;
	final fingerprint:Int;
	final nextMemo:Map<String, InlineMemo> = [];

	/** One entry per function being inlined: the callee functions it has consulted so far. */
	final frames:Array<Array<Int>> = [];

	/** The serial of each frame, and the serial of the frame that last recorded a function together with its dependencies. */
	final frameSerials:Array<Int> = [];

	final expandedBy:Array<Int> = [];
	var serials = 0;

	final frameIds:Array<Int> = [];
	final frameImpure:Array<Bool> = [];

	/** Parallel to `frames`: the objects each function being inlined has consulted so far. */
	final objectFrames:Array<Map<String, Bool>> = [];

	/** The objects consulted, with their prints, by each function inlined or reused so far. */
	final objectsOf:Array<Null<Map<String, Int>>> = [];

	var depth = 0;

	/**
	 * The strongly connected component of each function in the call graph of the original bodies. Inlining never goes into a call
	 * to a function of the caller's own component (a cycle): a function's inlined form then depends only on its own source and on
	 * the callees outside its component, not on where the walk happened to enter the cycle. Before, a call to an ancestor of the walk
	 * was skipped, which made the result depend on the order and kept every function in a cycle (and every caller of one) out of the
	 * memo.
	 */
	final components:Array<Int> = [];

	/**
	 * Inlined forms are memoized for the next compile (`IrInlineCache.memo`), which needs what each one consulted: the functions,
	 * the objects and their prints. A compile that keeps no session has no next compile, so it records none of it.
	 */
	final memoizes:Bool;

	/** The compile checks its reuse (`CompileOptions.checkReuse`): a function with a usable memo is inlined again and the two results must be equal. */
	final checkingMemo:Bool;

	/** Each inlined function goes through load/store forwarding and strength reduction, as the options ask. */
	final loadStoreForwarding:Bool;

	final strengthReduction:Bool;

	function new(program:IrProgram, cache:IrInlineCache, profile:TargetProfile, options:compiler.CompileOptions) {
		this.allowInline = options.inlining;
		this.loadStoreForwarding = options.loadStoreForwarding;
		this.strengthReduction = options.strengthReduction;
		this.checkingMemo = options.checkReuse;
		this.memoizes = options.keepSession;
		this.profile = profile;
		entryPoint = program.entryPoint;
		this.cache = cache;
		types = cache.types;
		voidType = types.id(Void);
		receiverCheckSymbol = IrSymbol.of(IrReceiverCheck.NAME).id;
		bodyLookup = pristineBody;
		methodLookup = resolveMethod;
		consultLookup = consultName;
		for (fn in program.functions)
			byName.set(fn.name, fn);
		var names = [for (name in byName.keys()) name];
		names.sort(Reflect.compare);
		for (name in names) {
			var symbol = IrSymbol.of(name);
			while (idsBySymbol.length <= symbol.id)
				idsBySymbol.push(-1);
			idsBySymbol[symbol.id] = functions.length;
			ids.set(name, functions.length);
			functions.push(byName.get(name));
			done.push(null);
			pristine.push(null);
			cleanedForms.push(null);
			sourceBodies.push(null);
			dependenciesOf.push(null);
			dependencyIdsOf.push(null);
			impure.push(false);
			visiting.push(false);
			objectsOf.push(null);
			components.push(-1);
			expandedBy.push(-1);
		}
		// What every function's inlining depends on whatever it looks at. Each object's own description is not here: a memo
		// entry records the objects it consulted, so a change to one object does not invalidate the rest.
		fingerprint = cache.fingerprintId([
			entryPoint,
			"profile=" + profile.key(),
			"inline=" + allowInline,
			"loadstore=" + loadStoreForwarding,
			"strength=" + strengthReduction
		].join(";"));
		var objects:Map<String, IrObject> = [],
			subclasses:Map<String, Array<String>> = [];
		for (object in program.objects) {
			objects.set(object.name, object);
			if (object.base != null) {
				var base = Std.string(object.base);
				if (!subclasses.exists(base))
					subclasses.set(base, []);
				subclasses.get(base).push(object.name);
			}
		}
		if (memoizes)
			for (name => object in objects) {
				var children = subclasses.get(name), text = describe(object);
				if (children != null) {
					var sorted = children.copy();
					sorted.sort(Reflect.compare);
					text += ">" + sorted.join(",");
				}
				objectPrints.set(name, cache.objectPrintId(name, text));
			}
		table = new IrObjectTable(objects, subclasses);
		resolution = IrMethodResolution.of(program);
		computeComponents();
	}

	/** Tarjan's algorithm over the call edges of the original bodies, visiting functions in name order so the numbering is deterministic. */
	function computeComponents():Void {
		var count = functions.length, edges:Array<Array<Int>> = [], copies = false;
		for (id in 0...count) {
			var targets:Array<Int> = [];
			var body = sourceBody(functions[id]);
			sourceSizes.push(body.instructionCount());
			for (block in 0...body.blockCount()) {
				var row = body.firstRow(block);
				while (row >= 0) {
					switch body.opcode(row) {
						case IrOpcode.ValueInit if (!copies && IrCopyElision.isValueCopyRow(body, row)):
							copies = true;
						case IrOpcode.Call:
							var target = functionId(body.aux(row));
							if (target >= 0)
								targets.push(target);
						case IrOpcode.MethodCall:
							var callee = resolveMethod(body.valueType(body.operand(row, 0)), body.symbol(row).name),
								target = callee == null ? null : ids.get(callee);
							if (target != null)
								targets.push(target);
						default:
					}
					row = body.nextRow(row);
				}
			}
			edges.push(targets);
		}
		ownsSources = !memoizes && !copies;
		var order:Array<Int> = [for (_ in 0...count) -1],
			low:Array<Int> = [for (_ in 0...count) 0],
			onStack:Array<Bool> = [for (_ in 0...count) false],
			stack:Array<Int> = [],
			counter = 0,
			component = 0;
		for (root in 0...count) {
			if (order[root] >= 0)
				continue;
			var path:Array<Int> = [root], cursors:Array<Int> = [0];
			order[root] = counter;
			low[root] = counter;
			counter++;
			stack.push(root);
			onStack[root] = true;
			while (path.length > 0) {
				var node = path[path.length - 1],
					cursor = cursors[cursors.length - 1],
					targets = edges[node];
				if (cursor < targets.length) {
					cursors[cursors.length - 1] = cursor + 1;
					var next = targets[cursor];
					if (order[next] < 0) {
						order[next] = counter;
						low[next] = counter;
						counter++;
						stack.push(next);
						onStack[next] = true;
						path.push(next);
						cursors.push(0);
					} else if (onStack[next] && order[next] < low[node])
						low[node] = order[next];
				} else {
					if (low[node] == order[node]) {
						var member:Int;
						do {
							var popped = stack.pop();
							if (popped == null)
								throw new InternalError("Strongly connected component stack emptied before its root");
							member = popped;
							onStack[member] = false;
							components[member] = component;
						} while (member != node);
						component++;
					}
					path.pop();
					cursors.pop();
					if (path.length > 0) {
						var parent = path[path.length - 1];
						if (low[node] < low[parent])
							low[parent] = low[node];
					}
				}
			}
		}
	}

	/** Include every field storage fact consulted by scalar replacement and load/store forwarding. */
	static function describe(object:IrObject):String {
		var methods = [for (method in object.methods) method.name + "=" + method.functionName].join(",");
		var fields = [for (field in object.fields)
			if (object.isValue
			|| IrFieldStorage.scalar(field) != null
			|| field.nullableScalarStorage != null
			|| (switch (field.type) {
				case F32: true;
				default: false;
			})) {
			var native = field.nativeLayout,
				scalar = IrFieldStorage.scalar(field),
				nullable = field.nullableScalarStorage;
			field.name
				+ "="
				+ IrTypeIdentity.text(field.type)
				+ (native == null ? ""
				: ':native=${native.offset}:${native.size}:${native.alignment}:${native.signed}:${native.inlineRecord}')
				+ (scalar == null ? "" : ':scalar=${scalar.size}:${scalar.signed}')
				+ (nullable == null ? "" : ':nullable=${nullable.size}:${nullable.signed}');
		}].join(",");
		return object.name + "<" + Std.string(object.base) + ":" + object.isValue + ":" + methods + ":" + fields;
	}

	/** The print an object has now; one that is not in the program has its own, which a class of that name would change. */
	function printOf(name:String):Int {
		var print = objectPrints.get(name);
		return print != null ? print : cache.objectPrintId(name, null);
	}

	function objectsCurrent(consulted:Map<String, Int>):Bool {
		for (name => print in consulted)
			if (printOf(name) != print)
				return false;
		return true;
	}

	/**
	 * Replaces every function that had a call inlined and returns the names whose inlined form differs from the one
	 * published by the previous compile. Those functions must be re-lowered and patched even when their own source did
	 * not change, because a callee they inlined did.
	 *
	 * The stage runs on bodies (docs/design/IR_CORE_COLUMNS.md): each function is encoded when it is first inlined, inlined,
	 * forwarded, reduced and cleaned up in place, and frozen at the end: `program.functions` holds each as its body
	 * (`IrFunction.ofBody`), which the HashLink lowering reads, decoded only for what still reads objects.
	 */
	/** Inlines `program`'s functions as `options` ask (the defaults, without them: every pass on, no reuse checks). */
	public static function run(program:IrProgram, cache:IrInlineCache, profile:TargetProfile,
			?options:compiler.CompileOptions,
			?instrument:IrInstrumentation.IrInstrumentationScope):Array<String> {
		program.functions = cache.stableSources(program.functions);
		var inliner = new IrInliner(program, cache, profile, options == null ? new compiler.CompileOptions() : options),
			functions:Array<IrFunction> = [],
			changed:Array<String> = [],
			relocated:Array<String> = [];
		var published:Map<String, IrFunction> = [],
			cleaned:Map<String, {source:IrBody, result:IrFunction}> = [],
			publishedBytes:Map<String, {fn:IrFunction, bytes:Null<Bytes>}> = [],
			instrumented:Map<String, {source:IrFunction, scope:String, result:IrFunction}> = [];
		// Every function is inlined before any is cleaned up: a caller inlines a callee's form before its cleanup, which edits it.
		var inlinedForms = [for (fn in program.functions) inliner.inlinedVersionOf(fn.name)];
		for (index in 0...program.functions.length) {
			var fn = program.functions[index], inlined = inlinedForms[index], result:IrFunction;
			// Keep inlining decisions based on the original post-inline bodies. Removing dead values in a memoized callee
			// would otherwise change the caller's budget and can introduce new allocations through a different expansion.
			var clean = cache.cleaned.get(fn.name);
			if (clean == null || clean.source != inlined) {
				var early = inliner.cleanedForms[inliner.ids.get(fn.name)];
				result = early != null ? early : inliner.cleanUp(fn, inlined);
				clean = {source: inlined, result: result};
			} else
				result = clean.result;
			// A compile that keeps no session has no next compile to reuse the cleaned form in.
			if (inliner.memoizes)
				cleaned.set(fn.name, clean);
			// Probes go in after inlining, into the published form only: a caller that inlines this function inlines it
			// without them.
			if (instrument != null) {
				var known = cache.instrumented.get(fn.name),
					key = instrument.key();
				if (known == null || known.source != result || known.scope != key)
					known = {source: result, scope: key, result: IrInstrumentation.apply(result, instrument)};
				instrumented.set(fn.name, known);
				result = known.result;
			}
			var previous = cache.published.get(fn.name);
			if (previous != null && previous != result) {
				// Generated functions (initializers, the entry) are rebuilt on every compile; only different bytes count.
				var previousEntry = cache.publishedBytes.get(fn.name);
				if (previousEntry == null || previousEntry.fn != previous)
					previousEntry = {fn: previous, bytes: encodeOrNull(previous)};
				var resultBytes = previousEntry.bytes == null ? null : encodeOrNull(result);
				if (resultBytes != null && previousEntry.bytes.compare(resultBytes) == 0) {
					// The same code on the same lines. One that only moved within its file keeps its new positions, so its
					// debug information names the snapshot this build carries; it is lowered again but needs no patch.
					if (IrFunctionStateCodec.samePlacement(previous, result)) {
						result = previous;
						// The next compile then finds the published form itself and compares nothing.
						if (instrument == null)
							cleaned.set(fn.name, {source: clean.source, result: previous});
					} else {
						relocated.push(fn.name);
						previousEntry = {fn: result, bytes: resultBytes};
					}
				} else {
					changed.push(fn.name);
					previousEntry = {fn: result, bytes: resultBytes};
				}
				publishedBytes.set(fn.name, previousEntry);
			} else if (previous == null)
				changed.push(fn.name);
			functions.push(result);
			published.set(fn.name, result);
			if (instrument != null)
				instrumented.get(fn.name).result = result;
		}
		program.functions = functions;
		// A compile that keeps no session reads the stage's output as bodies only (a session compares and caches the objects), so
		// once no callee is looked at any more an unchanged source keeps only its body.
		if (!inliner.memoizes) {
			for (fn in functions)
				if (fn.body != null)
					fn.releaseDecoded();
			cache.forgetSources();
		}
		IrOpportunityCensus.report(program, inliner.allowInline);
		IrAllocationReport.report(program);
		cache.memo = inliner.nextMemo;
		cache.cleaned = cleaned;
		cache.published = published;
		// Only functions that were compared have bytes; an entry for a function that is gone or unchanged-but-uncompared stays out.
		for (name => entry in cache.publishedBytes)
			if (!publishedBytes.exists(name) && published.get(name) == entry.fn)
				publishedBytes.set(name, entry);
		cache.publishedBytes = publishedBytes;
		cache.instrumented = instrumented;
		cache.relocated = relocated;
		inliner.keepOriginals();
		return changed;
	}

	/**
	 * A function's encoding for comparison, which leaves out the whole-file content hash and byte offsets so an edit elsewhere
	 * in the file does not make it look changed; its own lines and columns still count, so line information in stack traces
	 * stays right. Null when it cannot be encoded, which makes it count as different from anything.
	 */
	static function encodeOrNull(fn:IrFunction):Null<Bytes> {
		try {
			// Encoded once (`IrInlineCache.publishedBytes` keeps the bytes), from a decoding nothing keeps.
			var body = fn.body;
			return IrFunctionStateCodec.encodeForComparison(body != null ? body.toFunction() : fn);
		} catch (_:Dynamic) {
			return null;
		}
	}

	inline function functionId(symbol:Int):Int
		return symbol < idsBySymbol.length ? idsBySymbol[symbol] : -1;

	function inlinedVersionOf(name:String):Null<IrBody> {
		var id = ids.get(name);
		return id == null ? null : inlinedVersion(id);
	}

	/**
	 * The final cleanup of `fn`'s inlined form: in place when no caller may still inline the form as it is, else on a copy, or on
	 * `working`, the body the inlining edited when the memo keeps a compacted copy of it as `inlined`. The result is the frozen
	 * body, as a function decoded only when something reads its blocks (`IrFunction.ofBody`); a function nothing changed is its
	 * source, which keeps its body for the backends.
	 */
	function cleanUp(fn:IrFunction, inlined:IrBody, ?working:IrBody):IrFunction {
		var body = working != null ? working : inlined.frozen ? inlined.thaw(passScratch.bodyBuilder) : inlined,
			before = body.edits;
		IrJumpThreading.threadConstantBranchesBody(body, passScratch);
		IrScalarRefPromotion.runBody(body, passScratch);
		IrDeadPureValues.runBody(body, passScratch);
		IrReceiverCheckElision.runBody(body, passScratch);
		IrJumpThreading.runBody(body, passScratch);
		if (working != null && body.edits == before)
			return IrFunction.ofBody(inlined);
		var id = ids.get(fn.name);
		if (id != null && sourceBodies[id] == inlined && body.edits == before) {
			var own = fn.body;
			if (own == null)
				fn.keepBody(inlined.frozen ? inlined : inlined.freeze(memoizes, passScratch.bodyBuilder));
			else if (!own.frozen)
				own.freeze(false);
			return fn;
		}
		return IrFunction.ofBody(body.freeze(memoizes, passScratch.bodyBuilder));
	}

	/**
	 * The body of function `id` as its source has it, frozen: kept in the cache by name while the source is the same object, so
	 * a compile that keeps a session encodes an unchanged function once.
	 */
	function originalBody(id:Int):IrBody {
		var fn = functions[id], known = cache.originals.get(fn.name);
		if (known != null && known.source == fn)
			return known.body;
		var body = sourceBody(fn);
		cache.originals.set(fn.name, {source: fn, body: body});
		return body;
	}

	/**
	 * `fn`'s body as the stages before this one left it, frozen: the one it has (docs/design/IR_CORE_COLUMNS.md, the conversion
	 * point is before this stage), else its encoding, kept. A body made with other type ids (a session that started its cache
	 * over) cannot have rows spliced into this run's bodies, so it is encoded again, not kept.
	 */
	function sourceBody(fn:IrFunction):IrBody {
		var known = fn.body;
		if (known == null)
			return fn.bodyIn(types, passScratch.bodyBuilder, memoizes);
		return known.types == types ? known : IrBodyBuilder.encode(fn, types, passScratch.bodyBuilder).freeze(memoizes);
	}

	/** The cached frozen source body of function `id`, when the cache has one for its source. */
	function cachedOriginal(id:Int):Null<IrBody> {
		var fn = functions[id], known = cache.originals.get(fn.name);
		return known != null && known.source == fn ? known.body : null;
	}

	/** Drops the cached original bodies of functions that are gone or whose source changed. */
	function keepOriginals():Void {
		var kept:Map<String, {source:IrFunction, body:IrBody}> = [];
		for (fn in functions) {
			var known = cache.originals.get(fn.name);
			if (known != null && known.source == fn)
				kept.set(fn.name, known);
		}
		cache.originals = kept;
	}

	/** The body function `id`'s inlining edits: its source's, when the inliner owns it (`ownsSources`), else a copy of it. */
	function workingBody(id:Int):IrBody {
		if (memoizes)
			return originalBody(id).thaw(passScratch.bodyBuilder);
		var source = sourceBody(functions[id]);
		return ownsSources ? source.forEditing(passScratch.bodyBuilder) : source.thaw(passScratch.bodyBuilder);
	}

	/** The source body of the function named `name` (null for none), as copy elision reads its callees. */
	function pristineBody(name:String):Null<IrBody> {
		var id = ids.get(name);
		if (id == null)
			return null;
		if (memoizes)
			return originalBody(id);
		if (ownsSources)
			throw new InternalError('Copy elision read the source body of $name, which the inliner edits in place');
		var known = pristine[id];
		if (known == null) {
			known = sourceBody(functions[id]);
			pristine[id] = known;
		}
		return known;
	}

	/** Records a function copy elision consulted in the function being inlined. */
	function consultName(name:String):Void {
		var consultedId = ids.get(name);
		if (consultedId != null && frames.length > 0)
			frames[frames.length - 1].push(consultedId);
	}

	function inlinedVersion(id:Int):IrBody {
		var known = done[id];
		if (known != null) {
			consultResult(id);
			return known;
		}
		var original = functions[id], name = original.name;
		var memo = memoizes ? cache.memo.get(name) : null,
			usable = memo != null
				&& memo.source == original
				&& memo.fingerprint == fingerprint
				&& dependenciesCurrent(memo.dependencies)
				&& objectsCurrent(memo.objects);
		if (usable && !checkingMemo && memo != null) {
			done[id] = memo.result;
			dependenciesOf[id] = memo.dependencies;
			var memoDependencyIds:Array<Int> = [];
			for (dependency in memo.dependencies) {
				var dependencyId = ids.get(dependency.name);
				if (dependencyId == null)
					throw new InternalError('Inline memo of "$name" depends on unknown function "${dependency.name}"');
				memoDependencyIds.push(dependencyId);
			}
			dependencyIdsOf[id] = memoDependencyIds;
			objectsOf[id] = memo.objects;
			sourceBodies[id] = memo.result == cachedOriginal(id) ? memo.result : null;
			nextMemo.set(name, memo);
			consultResult(id);
			return memo.result;
		}
		visiting[id] = true;
		depth++;
		frameIds.push(id);
		frameImpure.push(false);
		var consultedObjects:Map<String, Bool> = [];
		if (memoizes) {
			frames.push([]);
			frameSerials.push(++serials);
			objectFrames.push(consultedObjects);
			table.consulted = consultedObjects;
		}
		var body = workingBody(id), before = body.edits;
		if (allowInline)
			inlineCalls(body);
		else if (profile.packedValueFields)
			IrScalarReplacement.runBody(body, table, passScratch, false, true);
		if (loadStoreForwarding)
			IrLoadStoreForwarding.runBody(body, table, passScratch);
		if (strengthReduction)
			IrStrengthReduction.runBody(body);

		// The memo holds the result as it is. Without one, callers inline the result as it is and the final cleanup, which runs
		// once every function is inlined, edits it in place.
		var unchanged = body.edits == before;
		var result = if (memoizes)
			unchanged ? originalBody(id) : body.freeze(memoizes, passScratch.bodyBuilder);
		else
			body;

		var isImpure = frameImpure.pop() == true;
		frameIds.pop();
		depth--;
		visiting[id] = false;
		if (!memoizes) {
			done[id] = result;
			sourceBodies[id] = unchanged ? result : null;
			return result;
		}
		objectFrames.pop();
		table.consulted = objectFrames.length > 0 ? objectFrames[objectFrames.length - 1] : null;
		var consulted = frames.pop();
		frameSerials.pop();
		// The functions consulted, once each and in name order (numbers are in name order).
		consulted.sort((left, right) -> left - right);
		var dependencies:Array<IrFunction> = [], dependencyIds:Array<Int> = [], last = -1;
		for (consultedId in consulted)
			if (consultedId != last) {
				last = consultedId;
				dependencies.push(functions[consultedId]);
				dependencyIds.push(consultedId);
			}
		var objectPrintsOf:Map<String, Int> =
			[for (objectName in consultedObjects.keys()) objectName => printOf(objectName)];
		if (usable && checkingMemo && memo != null) {
			if (!compiler.ir.codec.IrFunctionStateEquality.same(memo.result.toFunction(), result.toFunction()))
				throw new InternalError('--check-reuse: the inlined form of $name differs from the one its memo holds');
			result = memo.result;
		}
		done[id] = result;
		sourceBodies[id] = result == cachedOriginal(id) ? result : null;
		if (!unchanged)
			cleanedForms[id] = cleanUp(original, result, body);
		dependenciesOf[id] = dependencies;
		dependencyIdsOf[id] = dependencyIds;
		objectsOf[id] = objectPrintsOf;
		if (isImpure)
			impure[id] = true;
		else
			nextMemo.set(name, usable
				&& checkingMemo
				&& memo != null ? memo : new InlineMemo(original, fingerprint, dependencies, objectPrintsOf, result));
		consultResult(id);
		return result;
	}

	function dependenciesCurrent(dependencies:Array<IrFunction>):Bool {
		for (dependency in dependencies)
			if (byName.get(dependency.name) != dependency)
				return false;
		return true;
	}

	/** Records `name`'s pristine body and everything its inlined form depended on in the function being inlined. */
	function consultResult(id:Int):Void {
		if (frames.length == 0)
			return;
		var top = frames.length - 1, frame = frames[top];
		frame.push(id);
		// A function recorded with its dependencies in this frame needs no second expansion.
		if (expandedBy[id] == frameSerials[top])
			return;
		expandedBy[id] = frameSerials[top];
		var dependencyIds = dependencyIdsOf[id];
		if (dependencyIds != null)
			for (dependency in dependencyIds)
				frame.push(dependency);
		var consultedObjects = objectsOf[id];
		if (consultedObjects != null && objectFrames.length > 0) {
			var objectFrame = objectFrames[objectFrames.length - 1];
			for (objectName in consultedObjects.keys())
				objectFrame.set(objectName, true);
		}
		if (impure[id])
			frameImpure[frameImpure.length - 1] = true;
	}

	/** The inlined form of the function the call at `row` resolves to, when it can be inlined there, else null. */
	function calleeOf(body:IrBody, row:Int):Null<IrBody> {
		// A method call's actuals are its receiver, then its arguments: its operands, as a call's are its arguments.
		var id = -1;
		switch body.opcode(row) {
			case IrOpcode.Call:
				id = functionId(body.aux(row));
			case IrOpcode.MethodCall:
				var target = resolveMethod(body.valueType(body.operand(row, 0)), IrSymbol.at(body.aux(row) >> 1).name),
					known = target == null ? null : ids.get(target);
				if (known != null)
					id = known;
			default:
		}
		if (id < 0)
			return null;
		var original = functions[id];
		if (frames.length > 0)
			frames[frames.length - 1].push(id);
		// A call into the caller's own cycle is never inlined (see `components`); this covers recursion and every ancestor of the walk.
		if (frameIds.length > 0 && components[id] == components[frameIds[frameIds.length - 1]])
			return null;
		if (visiting[id]) {
			// Unreachable now (an ancestor is always in the caller's component); kept as the guard it was.
			frameImpure[frameImpure.length - 1] = true;
			return null;
		}
		if (depth > MaxChainDepth) {
			if (frameImpure.length > 0)
				frameImpure[frameImpure.length - 1] = true;
			return null;
		}
		var count = body.operandCount(row);
		if (IrTypedInterfaceDispatch.isDispatchEntry(original.name)
			|| IrTypedInterfaceDispatch.isAdapterEntry(original.name)
			|| original.arguments.length != count
			|| !looksInlinable(id))
			return null;
		for (index in 0...count)
			if (!bindable(body.valueType(body.operand(row, index)), original.arguments[index].type))
				return null;
		var candidate = inlinedVersion(id);
		if (candidate == null || !fits(candidate))
			return null;
		// HashLink's JIT keeps registers only inside a basic block, so a branching body costs more spliced in than called;
		// only a straight-line body, or one the author marked inline, is worth it.
		return isStraightLine(candidate) || candidate.inlineHint ? candidate : null;
	}

	/**
	 * The function a method call on a receiver of type `receiver` reaches, when the receiver's class and all its subclasses run
	 * the same one. A value class is final, so its methods always resolve. Anything else can be overridden only by a class in
	 * this program: patches cannot add classes, so a live module cannot introduce another override.
	 */
	public function resolveMethod(receiver:IrType, method:String):Null<String> {
		var typeName = switch receiver {
			case Obj(name): name;
			default: return null;
		};
		// The answer comes from the shared table; what the walk used to read is recorded for the memo's dependencies: the class
		// and its bases, and every class that extends it.
		var consulted = table.consulted;
		if (consulted != null) {
			var name:Null<String> = typeName;
			while (name != null) {
				var descriptor = table.get(name);
				name = descriptor == null || descriptor.base == null ? null : Std.string(descriptor.base);
			}
			for (name in resolution.subtreeOf(typeName))
				consulted.set(name, true);
		}
		// A call on a class with more than MaxSubclassWalk classes below it stays unresolved, as it did when this walked the subclasses
		// itself and gave up after that many. Lifting the limit resolves calls on very wide hierarchies (MachineComponent in the app),
		// which changes the output, so it is a separate measured step.
		return resolution.subtreeOf(typeName).length > MaxSubclassWalk
			? null : resolution.uniqueImplementation(typeName, method);
	}

	/** Cheap syntactic screen on function `id`'s original body, before the callee's own calls are inlined. */
	function looksInlinable(id:Int):Bool {
		var fn = functions[id];
		if (StringTools.startsWith(fn.name, "__") || fn.name == entryPoint)
			return false;
		return sourceSizes[id] <= (fn.inlineHint ? HintBudget : SmallBudget) * 2;
	}

	static function fits(fn:IrBody):Bool {
		if (fn.blockCount() > MaxBlocks || fn.instructionCount() > (fn.inlineHint ? HintBudget : SmallBudget))
			return false;
		var returns = 0;
		for (block in 0...fn.blockCount()) {
			var row = fn.firstRow(block);
			while (row >= 0) {
				switch fn.opcode(row) {
					case IrOpcode.BeginTry, IrOpcode.EndTry, IrOpcode.Catch:
						return false;
					default:
				}
				row = fn.nextRow(row);
			}
			var terminator = fn.terminatorRow(block);
			if (terminator < 0)
				return false;
			if (fn.opcode(terminator) == IrOpcode.Return)
				returns++;
		}
		return returns > 0;
	}

	static function isStraightLine(fn:IrBody):Bool {
		if (fn.blockCount() != 1)
			return false;
		var terminator = fn.terminatorRow(0);
		return terminator >= 0 && fn.opcode(terminator) == IrOpcode.Return;
	}

	/**
	 * Inlines the calls of `body` in place: a straight-line callee's rows are spliced in place of the call, a branching one's
	 * blocks expanded after the call's block, which is split there; then the values the calls returned replace their outputs,
	 * and scalar replacement and copy elision run over the result.
	 */
	function inlineCalls(body:IrBody):Void {
		// Runtime helpers (initializers, the entry) are patched specially; nothing is ever inlined into them.
		if (StringTools.startsWith(body.name, "__"))
			return;
		var found = false;
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0 && !found) {
				if (calleeOf(body, row) != null)
					found = true;
				row = body.nextRow(row);
			}
			if (found)
				break;
		}
		if (!found)
			for (block in 0...body.blockCount()) {
				var row = body.firstRow(block);
				while (row >= 0 && !found) {
					if (body.opcode(row) == IrOpcode.ValueInit) {
						var object =
							table.get(compiler.ir.IrTypeTools.valueObjectName(body.valueType(body.output(row))));
						if (object != null && object.isValue)
							found = true;
					}
					row = body.nextRow(row);
				}
				if (found)
					break;
			}
		if (!found && !IrCopyElision.hasCopiesBody(body))
			return;
		var nextBlock = 0;
		for (block in 0...body.blockCount())
			if (body.blockId(block) >= nextBlock)
				nextBlock = body.blockId(block) + 1;
		var index = 0, inlines = 0, instructions = body.instructionCount();
		while (index < body.blockCount()) {
			var call = -1, callee:Null<IrBody> = null;
			if (inlines < MaxInlinesPerFunction && instructions < MaxFunctionInstructions) {
				var row = body.firstRow(index);
				while (row >= 0) {
					callee = calleeOf(body, row);
					if (callee != null) {
						call = row;
						break;
					}
					row = body.nextRow(row);
				}
			}
			if (callee == null) {
				index++;
				continue;
			}
			inlines++;
			instructions += callee.instructionCount();
			if (isStraightLine(callee)) {
				// Splice into the calling block: no new block, no phi. Rescan the block; the spliced calls were not candidates.
				spliceCall(body, index, call, callee);
				continue;
			}
			nextBlock = expandCall(body, index, call, callee, nextBlock, needsReceiverCheck(body, call));
			// Continue with the first inlined block; calls left in it were not candidates.
			index++;
		}
		body.sweepAliases();
		IrScalarReplacement.runBody(body, table, passScratch, false, profile.packedValueFields);
		IrCopyElision.runBody(body, bodyLookup, methodLookup, consultLookup, passScratch);
	}

	/** Value receivers are non-null values; reference receivers must retain the method call's null check. */
	function needsReceiverCheck(body:IrBody, call:Int):Bool {
		if (body.opcode(call) != IrOpcode.MethodCall)
			return false;
		return switch body.valueType(body.operand(call, 0)) {
			case Obj(name): var object = table.get(name);
				object == null || !object.isValue;
			default: true;
		};
	}

	/** Callee rows are copied as they are, so the callee's type ids must be the caller's. */
	function sameTypeIds(body:IrBody, callee:IrBody):Void {
		if (body.types != types || callee.types != types)
			throw new InternalError('Inliner found ${callee.name} or ${body.name} with type ids of another program');
	}

	/**
	 * Replaces the call at row `call` of block `block` (an index) by the straight-line callee's rows, values renamed: its
	 * receiver check and upcasts, its instructions, and a `ConstVoid` for a void call; otherwise the call's output stands for
	 * the value the callee returned (an alias, swept after the last call is inlined).
	 */
	function spliceCall(body:IrBody, block:Int, call:Int, callee:IrBody):Void {
		sameTypeIds(body, callee);
		var where = body.provenance(call), output = body.output(call), rows = madeRows;
		rows.resize(0);
		var values = IrPassScratch.filledInts(calleeValues, callee.valueLimit(), -1);
		if (needsReceiverCheck(body, call)) {
			var checked = body.newValue("$receiver-check", voidType);
			body.beginRow();
			body.pushOperand(body.resolve(body.operand(call, 0)));
			rows.push(body.endRow(IrOpcode.Call, checked, receiverCheckSymbol, where));
		}
		bindArgumentValues(body, call, callee, values, rows, where, true);
		var terminator = callee.terminatorRow(0), row = callee.firstRow(0);
		while (row >= 0 && row != terminator) {
			defineCalleeValue(body, callee, row, values);
			row = callee.nextRow(row);
		}
		row = callee.firstRow(0);
		while (row >= 0 && row != terminator) {
			rows.push(body.copyRow(callee, row, values));
			row = callee.nextRow(row);
		}
		if (terminator < 0 || callee.opcode(terminator) != IrOpcode.Return)
			throw new InternalError("A straight-line callee must return");
		var returned = calleeValue(values, callee.operand(terminator, 0));
		if (body.valueTypeId(output) == voidType) {
			body.beginRow();
			rows.push(body.endRow(IrOpcode.ConstVoid, output, 0, where));
		} else
			body.alias(output, returned);
		for (made in rows)
			body.linkBefore(block, call, made);
		body.removeRow(block, call);
	}

	/** Gives the callee row's output, when it has one, a new value of the caller. */
	static inline function defineCalleeValue(body:IrBody, callee:IrBody, row:Int, values:Array<Int>):Void {
		var out = callee.output(row);
		if (out.exists())
			values[out] = body.newValue(callee.valueName(out), callee.valueTypeId(out));
	}

	static function calleeValue(values:Array<Int>, value:IrValueId):IrValueId {
		var mapped = (value:Int) < values.length ? values[value] : -1;
		if (mapped < 0)
			throw new InternalError("Inliner found an undefined callee value");
		return IrValueId.of(mapped);
	}

	/**
	 * Binds the callee's parameters to the call's operands (resolved through the aliases when `resolved`). A call passes an
	 * object of a subclass where its parameter takes the base class; inlined, that value is upcast first (a row made in `rows`),
	 * so the body keeps the types it was verified with.
	 */
	function bindArgumentValues(body:IrBody, call:Int, callee:IrBody, values:Array<Int>, rows:Array<Int>,
			where:SourceProvenance, resolved:Bool):Void {
		for (index in 0...callee.argumentCount()) {
			var formal = callee.argument(index), actual = body.operand(call, index);
			if (resolved)
				actual = body.resolve(actual);
			var formalType = callee.valueTypeId(formal), actualType = body.valueTypeId(actual);
			if (formalType == actualType || IrVerifier.sameType(types.type(actualType), types.type(formalType)))
				values[formal] = actual;
			else {
				var upcast = body.newValue(callee.valueName(formal), formalType);
				body.beginRow();
				body.pushOperand(actual);
				rows.push(body.endRow(IrOpcode.Upcast, upcast, 0, where));
				values[formal] = upcast;
			}
		}
	}

	/**
	 * Replaces the call at row `call` of block `head` (an index) by a copy of the branching callee. The head keeps the rows
	 * before the call, then the receiver check and upcasts, and jumps into the copy, whose blocks follow it with new ids; a new
	 * continuation block merges the returned values with a phi and takes the rows after the call and the head's terminator.
	 * Gives the next free block id.
	 */
	function expandCall(body:IrBody, head:Int, call:Int, callee:IrBody, nextBlock:Int, checkReceiver:Bool):Int {
		sameTypeIds(body, callee);
		var where = body.provenance(call), output = body.output(call), headId = body.blockId(head), rows = madeRows;
		rows.resize(0);
		var values = IrPassScratch.filledInts(calleeValues, callee.valueLimit(), -1);
		if (checkReceiver) {
			var checked = body.newValue("$receiver-check", voidType);
			body.beginRow();
			body.pushOperand(body.operand(call, 0));
			rows.push(body.endRow(IrOpcode.Call, checked, receiverCheckSymbol, where));
		}
		bindArgumentValues(body, call, callee, values, rows, where, false);
		// Every definition first, so phis and back edges can refer to values defined later in block order.
		var blockLimit = 0;
		for (block in 0...callee.blockCount())
			if (callee.blockId(block) >= blockLimit)
				blockLimit = callee.blockId(block) + 1;
		var blocks = IrPassScratch.filledInts(calleeBlocks, blockLimit, -1);
		for (block in 0...callee.blockCount()) {
			blocks[callee.blockId(block)] = nextBlock++;
			var terminator = callee.terminatorRow(block), row = callee.firstRow(block);
			while (row >= 0 && row != terminator) {
				defineCalleeValue(body, callee, row, values);
				row = callee.nextRow(row);
			}
		}
		var continuation = nextBlock++;
		// Everything that used to leave the head will leave the continuation, so successor phis name the new predecessor.
		var headTerminator = body.terminatorRow(head);
		if (headTerminator < 0)
			throw new InternalError("Inliner found a call site without a terminator");
		var successors = successorIds;
		successors.resize(0);
		switch body.opcode(headTerminator) {
			case IrOpcode.Jump:
				successors.push(body.aux(headTerminator));
			case IrOpcode.Branch:
				successors.push(body.auxInt(headTerminator, 0));
				successors.push(body.auxInt(headTerminator, 1));
			default:
		}
		var row = body.nextRow(call);
		while (row >= 0) {
			if (body.opcode(row) == IrOpcode.BeginTry) {
				successors.push(body.auxInt(row, 0));
				successors.push(body.auxInt(row, 1));
			}
			row = body.nextRow(row);
		}
		for (block in 0...body.blockCount())
			if (successors.indexOf(body.blockId(block)) >= 0)
				retargetPhiInputs(body, block, block == head ? call : -1, headId, continuation);
		// The callee's blocks after the head, then the continuation.
		var count = callee.blockCount(), after = head + 1 + count;
		for (block in 0...count)
			body.addBlock(head + 1 + block, blocks[callee.blockId(block)]);
		body.addBlock(after, continuation);
		returnedValues.resize(0);
		returnedBlocks.resize(0);
		for (block in 0...count) {
			var into = head + 1 + block;
			if (callee.terminatorRow(block) < 0)
				throw new InternalError("Inliner found a callee block without a terminator");
			row = callee.firstRow(block);
			while (row >= 0) {
				if (callee.opcode(row) == IrOpcode.Return) {
					returnedBlocks.push(body.blockId(into));
					returnedValues.push(calleeValue(values, callee.operand(row, 0)));
					body.beginRow();
					body.linkBefore(into, -1,
						body.endRow(IrOpcode.Jump, IrValueId.of(-1), continuation, callee.provenance(row)));
				} else
					body.linkBefore(into, -1, body.copyRow(callee, row, values, blocks));
				row = callee.nextRow(row);
			}
		}
		// The continuation defines the call's output, then runs whatever followed the call.
		var tail = body.nextRow(call);
		body.removeRow(head, call);
		body.beginRow();
		var merge = if (body.valueTypeId(output) == voidType)
			body.endRow(IrOpcode.ConstVoid, output, 0, where);
		else {
			for (value in returnedValues)
				body.pushOperand(IrValueId.of(value));
			var start = body.pushInt(returnedBlocks[0]);
			for (index in 1...returnedBlocks.length)
				body.pushInt(returnedBlocks[index]);
			body.endRow(IrOpcode.Phi, output, start, where);
		}
		body.linkBefore(after, -1, merge);
		body.moveTail(head, tail, after);
		for (made in rows)
			body.linkBefore(head, -1, made);
		body.beginRow();
		body.linkBefore(head, -1, body.endRow(IrOpcode.Jump, IrValueId.of(-1), blocks[callee.blockId(0)], where));
		return nextBlock;
	}

	/** Makes every phi input of block `block` (an index) from block id `from` come from `to`, the rows before `stop` only. */
	static function retargetPhiInputs(body:IrBody, block:Int, stop:Int, from:Int, to:Int):Void {
		var row = body.firstRow(block);
		while (row >= 0 && row != stop) {
			if (body.opcode(row) == IrOpcode.Phi)
				for (index in 0...body.operandCount(row))
					if (body.auxInt(row, index) == from)
						body.setAuxInt(row, index, to);
			row = body.nextRow(row);
		}
	}
	/**
	 * Binds the callee's parameters to the caller's arguments. A call passes an object of a subclass where its parameter
	 * takes the base class; spliced in, that value is upcast first, so the body keeps the types it was verified with.
	 */
	static function bindArguments(callee:IrFunction, actuals:Array<IrValue>, values:Map<Int, IrValue>,
			upcasts:Array<Located<IrInstruction>>,
			provenance:SourceProvenance, nextValue:Int):Int {
		for (index in 0...callee.arguments.length) {
			var formal = callee.arguments[index], actual = actuals[index];
			if (IrVerifier.sameType(actual.type, formal.type))
				values.set(formal.id, actual);
			else {
				var upcast = new IrValue(nextValue++, formal.name, formal.type);
				upcasts.push(new Located(Upcast(upcast, actual), provenance));
				values.set(formal.id, upcast);
			}
		}
		return nextValue;
	}

	/** Whether a caller's argument can stand for a callee's parameter: the same type, or an object where its base class is taken. */
	static function bindable(actual:IrType, formal:IrType):Bool
		return IrVerifier.sameType(actual, formal) || switch [actual, formal] {
			case [Obj(_), Obj(_)]: true;
			default: false;
		};

	static function resolve(value:IrValue, substitutions:Map<Int, IrValue>):IrValue {
		var current = value, steps = 0;
		while (substitutions.exists(current.id) && steps < 4096) {
			current = substitutions.get(current.id);
			steps++;
		}
		return current;
	}

	/**
	 * Rewrites every use of a spliced call's output to the value the callee returned, in place. Only the instructions and
	 * terminators that use a substituted value are replaced; the bindings come back as given when none names one.
	 */
	public static function substitute(blocks:Array<IrBlock>, substitutions:Map<Int, IrValue>,
			bindings:Array<IrDebugBinding>):Array<IrDebugBinding> {
		var use = function(value:IrValue):IrValue return resolve(value, substitutions);
		var substituted = function(value:IrValue):Bool return substitutions.exists(value.id);
		var sameBlock = function(id:Int):Int return id;
		for (block in blocks) {
			for (position in 0...block.instructions.length) {
				var located = block.instructions[position];
				if (IrOperands.anyValue(located.value, substituted))
					block.instructions[position] = new Located(remap(located.value, use, sameBlock),
						located.provenance);
			}
			var terminator = block.terminator;
			if (terminator != null) {
				var rewritten:Null<IrTerminator> = switch terminator.value {
					case Unreachable, Jump(_): null;
					case Return(value): substituted(value) ? Return(use(value)) : null;
					case Throw(value): substituted(value) ? Throw(use(value)) : null;
					case Rethrow(value): substituted(value) ? Rethrow(use(value)) : null;
					case Branch(condition, whenTrue, whenFalse): substituted(condition) ? Branch(use(condition),
						whenTrue,
						whenFalse) : null;
					case Switch(switchValue, switchTargets, switchOtherwise): substituted(switchValue)
						? Switch(use(switchValue),
						switchTargets.copy(), switchOtherwise) : null;
				};
				if (rewritten != null)
					block.terminator = new Located(rewritten, terminator.provenance);
			}
		}
		var renamed = false;
		for (binding in bindings)
			if (substituted(binding.value)) {
				renamed = true;
				break;
			}
		if (!renamed)
			return bindings;
		return [for (binding in bindings)
			substituted(binding.value) ? {
				identity: binding.identity,
				name: binding.name,
				value: use(binding.value),
				path: binding.path,
				scopeStart: binding.scopeStart,
				scopeEnd: binding.scopeEnd
			} : binding];
	}

	/**
	 * Replaces the call at `blocks[index].instructions[position]` by a copy of `callee`. The block keeps the
	 * instructions before the call and jumps into the copy; a fresh continuation block takes the instructions after the
	 * call and the original terminator, and merges the returned values with a phi.
	 */
	public static function expand(blocks:Array<IrBlock>, index:Int, position:Int, callee:IrFunction, nextValue:Int,
			nextBlock:Int,
			?checkReceiver:Bool):{
				nextValue:Int,
				nextBlock:Int
			} {
		var head = blocks[index],
			call = head.instructions[position],
			callOutput:IrValue = null,
			actuals:Array<IrValue> = [];
		switch call.value {
			case Call(out, _, arguments):
				callOutput = out;
				actuals = arguments;
			case MethodCall(out, object, _, arguments, _):
				callOutput = out;
				actuals = [object].concat(arguments);
			default:
				throw new InternalError("Inliner expected a call");
		}
		var values:Map<Int, IrValue> = [],
			blockIds:Map<Int, Int> = [],
			upcasts:Array<Located<IrInstruction>> = [];
		var mustCheck = checkReceiver == null ? switch call.value {
			case MethodCall(_, _, _, _, _): true;
			default: false;
		} : checkReceiver;
		if (mustCheck) {
			var checked = new IrValue(nextValue++, "$receiver-check", Void);
			upcasts.push(new Located(Call(checked, IrSymbol.of(IrReceiverCheck.NAME), [actuals[0]]), call.provenance));
		}
		nextValue = bindArguments(callee, actuals, values, upcasts, call.provenance, nextValue);
		// Every definition first, so phis and back edges can refer to values defined later in block order.
		for (block in callee.blocks) {
			blockIds.set(block.id, nextBlock++);
			for (located in block.instructions) {
				var output = IrOperands.output(located.value);
				if (output != null) {
					values.set(output.id, new IrValue(nextValue++, output.name, output.type));
				}
			}
		}
		var continuation = new IrBlock(nextBlock++);
		var use = function(value:IrValue):IrValue {
			var mapped = values.get(value.id);
			if (mapped == null)
				throw new InternalError("Inliner found an undefined callee value");
			return mapped;
		};
		var target = function(id:Int):Int {
			var mapped = blockIds.get(id);
			if (mapped == null)
				throw new InternalError("Inliner found an unknown callee block");
			return mapped;
		};
		var cloned:Array<IrBlock> = [], returned:Array<IrPhiInput> = [];
		for (block in callee.blocks) {
			var copy = new IrBlock(target(block.id));
			for (located in block.instructions)
				copy.instructions.push(new Located(remap(located.value, use, target), located.provenance));
			var terminator = block.terminator;
			if (terminator == null)
				throw new InternalError("Inliner found a callee block without a terminator");
			switch terminator.value {
				case Unreachable:
					copy.terminator = new Located(Unreachable, terminator.provenance);
				case Return(value):
					returned.push({block: copy.id, value: use(value)});
					copy.terminator = new Located(Jump(continuation.id), terminator.provenance);
				case Throw(value):
					copy.terminator = new Located(Throw(use(value)), terminator.provenance);
				case Rethrow(value):
					copy.terminator = new Located(Rethrow(use(value)), terminator.provenance);
				case Jump(destination):
					copy.terminator = new Located(Jump(target(destination)), terminator.provenance);
				case Branch(condition, whenTrue, whenFalse):
					copy.terminator = new Located(Branch(use(condition), target(whenTrue), target(whenFalse)),
						terminator.provenance);
				case Switch(value, targets, otherwise):
					copy.terminator = new Located(Switch(use(value), IrSwitch.mapTargets(targets, target),
						target(otherwise)),
						terminator.provenance);
			}
			cloned.push(copy);
		}
		// The continuation defines the call's output, then runs whatever followed the call.
		if ((switch (callOutput.type) {
			case Void: true;
			default: false;
		}))
			continuation.instructions.push(new Located(ConstVoid(callOutput), call.provenance));
		else
			continuation.instructions.push(new Located(Phi(callOutput, returned), call.provenance));
		for (rest in position + 1...head.instructions.length)
			continuation.instructions.push(head.instructions[rest]);
		continuation.terminator = head.terminator;
		head.instructions.resize(position);
		for (upcast in upcasts)
			head.instructions.push(upcast);
		head.terminator = new Located(Jump(cloned[0].id), call.provenance);
		// Everything that used to leave the head now leaves the continuation, so successor phis name the new predecessor.
		var successors:Array<Int> = [];
		var continued = continuation.terminator;
		if (continued == null)
			throw new InternalError("Inliner found a call site without a terminator");
		switch continued.value {
			case Jump(destination):
				successors.push(destination);
			case Branch(_, whenTrue, whenFalse):
				successors.push(whenTrue);
				successors.push(whenFalse);
			default:
		}
		for (located in continuation.instructions)
			switch located.value {
				case BeginTry(catchBlock, afterBlock, _):
					successors.push(catchBlock);
					successors.push(afterBlock);
				default:
			}
		for (candidate in blocks)
			if (successors.indexOf(candidate.id) >= 0)
				retargetPhis(candidate, head.id, continuation.id);
		var insertion:Array<IrBlock> = cloned.concat([continuation]);
		var at = index + 1;
		for (added in insertion) {
			blocks.insert(at, added);
			at++;
		}
		return {nextValue: nextValue, nextBlock: nextBlock};
	}

	static function retargetPhis(block:IrBlock, from:Int, to:Int):Void {
		for (position in 0...block.instructions.length) {
			var located = block.instructions[position];
			switch located.value {
				case Phi(output, inputs):
					var changed = false, updated:Array<IrPhiInput> = [];
					for (input in inputs) {
						if (input.block == from) {
							changed = true;
							updated.push({block: to, value: input.value});
						} else
							updated.push(input);
					}
					if (changed)
						block.instructions[position] = new Located(Phi(output, updated), located.provenance);
				default:
			}
		}
	}

	/** The instruction with every value (inputs and outputs alike) passed through `use` and every block id through `block`. */
	public static function remap(instruction:IrInstruction, use:IrValue->IrValue, block:Int->Int):IrInstruction {
		return switch instruction {
			case Phi(out, inputs): Phi(use(out), [for (input in inputs) {
					block:block(input.block), value:use(input.value)
				}]);
			case ConstVoid(out): ConstVoid(use(out));
			case ConstInt(out, value): ConstInt(use(out), value);
			case ConstFloat(out, value): ConstFloat(use(out), value);
			case ConstString(out, value): ConstString(use(out), value);
			case StaticDataAddress(out, bytes): StaticDataAddress(use(out), bytes);
			case PointerOffset(out, pointer, offset): PointerOffset(use(out), use(pointer), use(offset));
			case MemoryLoad(out, pointer, size, signed): MemoryLoad(use(out), use(pointer), size, signed);
			case MemoryStore(pointer, value, size): MemoryStore(use(pointer), use(value), size);
			case ConstBool(out, value): ConstBool(use(out), value);
			case ConstNull(out): ConstNull(use(out));
			case TypeValue(out, type): TypeValue(use(out), type);
			case ToDyn(out, value): ToDyn(use(out), use(value));
			case IntToFloat(out, value): IntToFloat(use(out), use(value));
			case IntToInt64(out, value): IntToInt64(use(out), use(value));
			case FloatToInt(out, value): FloatToInt(use(out), use(value));
			case FloatToFloat(out, value): FloatToFloat(use(out), use(value));
			case SafeCast(out, value): SafeCast(use(out), use(value));
			// Callees with handlers are never cloned (see fits); these arise when a caller is rewritten in place.
			case BeginTry(catchBlock, afterBlock, preserveExceptionStack): BeginTry(block(catchBlock),
				block(afterBlock), preserveExceptionStack);
			case EndTry(catchBlock, preserveExceptionStack): EndTry(block(catchBlock), preserveExceptionStack);
			case Catch(out): Catch(use(out));
			case GlobalGet(out, name): GlobalGet(use(out), name);
			case GlobalSet(name, value): GlobalSet(name, use(value));
			case Add(out, a, b): Add(use(out), use(a), use(b));
			case Sub(out, a, b): Sub(use(out), use(a), use(b));
			case Mul(out, a, b): Mul(use(out), use(a), use(b));
			case Div(out, a, b): Div(use(out), use(a), use(b));
			case Mod(out, a, b): Mod(use(out), use(a), use(b));
			case BitAnd(out, a, b): BitAnd(use(out), use(a), use(b));
			case BitXor(out, a, b): BitXor(use(out), use(a), use(b));
			case BitOr(out, a, b): BitOr(use(out), use(a), use(b));
			case ShiftLeft(out, a, b): ShiftLeft(use(out), use(a), use(b));
			case ShiftRight(out, a, b): ShiftRight(use(out), use(a), use(b));
			case UnsignedShiftRight(out, a, b): UnsignedShiftRight(use(out), use(a), use(b));
			case Less(out, a, b): Less(use(out), use(a), use(b));
			case LessEqual(out, a, b): LessEqual(use(out), use(a), use(b));
			case Equal(out, a, b): Equal(use(out), use(a), use(b));
			case Call(out, name, arguments): Call(use(out), name, [for (argument in arguments) use(argument)]);
			case Intrinsic(out, operation, arguments): Intrinsic(use(out), operation,
				[for (argument in arguments) use(argument)]);
			case CNativeCall(out, name, arguments): CNativeCall(use(out), name,
				[for (argument in arguments) use(argument)]);
			case StaticClosure(out, name): StaticClosure(use(out), name);
			case InstanceClosure(out, name, receiver): InstanceClosure(use(out), name, use(receiver));
			case CallClosure(out, closure, arguments): CallClosure(use(out), use(closure),
				[for (argument in arguments) use(argument)]);
			case ToVirtual(out, value): ToVirtual(use(out), use(value));
			case Upcast(out, value): Upcast(use(out), use(value));
			case ClassId(out, value): ClassId(use(out), use(value));
			case MethodCall(out, object, name, arguments,
				terminalReceiver): MethodCall(use(out), use(object), name, [for (argument in arguments) use(argument)],
				terminalReceiver);
			case NewObject(out, typeName): NewObject(use(out), typeName);
			case ValueInit(out): ValueInit(use(out));
			case FieldGet(out, object, name): FieldGet(use(out), use(object), name);
			case FieldSet(object, name, value): FieldSet(use(object), name, use(value));
			case ArrayGet(out, array, index): ArrayGet(use(out), use(array), use(index));
			case ArraySet(array, index, value): ArraySet(use(array), use(index), use(value));
			case ArraySize(out, array): ArraySize(use(out), use(array));
			case IteratorNew(out, array): IteratorNew(use(out), use(array));
			case IteratorHasNext(out, iterator): IteratorHasNext(use(out), use(iterator));
			case IteratorNext(out, iterator): IteratorNext(use(out), use(iterator));
			case MakeEnum(out, typeName, constructor, arguments): MakeEnum(use(out), typeName, constructor,
				[for (argument in arguments) use(argument)]);
			case EnumIndex(out, value): EnumIndex(use(out), use(value));
			case EnumField(out, value, constructor, field): EnumField(use(out), use(value), constructor, field);
		};
	}
}
