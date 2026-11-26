package compiler.ir.passes.inlining;

import compiler.ir.tools.IrInstrumentation.IrInstrumentationScope;
import compiler.ir.model.IrBody;
import compiler.ir.passes.cleanup.IrCopyElision;
import compiler.ir.passes.cleanup.IrDeadPureValues;
import compiler.ir.model.IrFieldStorage;
import compiler.ir.tools.IrInstrumentation;
import compiler.ir.passes.cleanup.IrJumpThreading;
import compiler.ir.passes.cleanup.IrLoadStoreForwarding;
import compiler.ir.analysis.IrMethodResolution;
import compiler.ir.model.IrObjectTable;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrOperands;
import compiler.ir.tools.IrOpportunityCensus;
import compiler.ir.model.IrPassScratch;
import compiler.ir.names.IrReceiverCheck;
import compiler.ir.passes.cleanup.IrReceiverCheckElision;
import compiler.ir.passes.scalars.IrScalarRefPromotion;
import compiler.ir.passes.scalars.IrScalarReplacement;
import compiler.ir.passes.cleanup.IrStrengthReduction;
import compiler.ir.model.IrSymbol;
import compiler.ir.model.IrTypeIdentity;
import compiler.ir.model.IrTypeIds;
import compiler.ir.passes.objects.IrTypedInterfaceDispatch;
import compiler.ir.verify.IrVerifier;
import compiler.ir.pipeline.TargetProfile;

import compiler.core.InternalError;
import compiler.ir.codec.IrFunctionStateEquality;
import compiler.ir.model.Ir;
import compiler.ir.model.IrFunction;
import compiler.ir.model.SourceProvenance;
import compiler.ir.model.SourceProvenance.Located;
import compiler.ir.pipeline.IrFunctionPass.IrFactSource;
import compiler.ir.reuse.IrStageFacts;
import compiler.ir.reuse.IrStageMemo.IrStageMemos;
import compiler.query.ComputedQueryKind;
import compiler.query.QueryDatabase;
import compiler.query.QueryKind.QueryRead;

/** A function's inlined form as the inliner's kind keeps it (`IrInlineQueries.forms`): no body when no caller may splice it. */
@:nullSafety(Strict)
class IrInlinedForm {
	@:processWide("the form of every function no caller may splice, only ever read")
	public static final NONE = new IrInlinedForm(null);

	public final body:Null<IrBody>;

	/** Whether a caller may splice `body` (`IrInliner.spliceableForm`), worked out once for the form. */
	public final splices:Bool;

	public function new(body:Null<IrBody>) {
		this.body = body;
		splices = body != null && IrInliner.spliceableForm(body);
	}

	/** Whether two forms give a caller the same: neither may be spliced, or both may and their bodies are the same. */
	public static function same(left:IrInlinedForm, right:IrInlinedForm):Bool {
		if (left.splices != right.splices)
			return false;
		var leftBody = left.body, rightBody = right.body;
		return !left.splices || leftBody != null && rightBody != null
			&& IrFunctionStateEquality.sameBodies(leftBody, rightBody);
	}
}

/**
 * What a caller reads of a function before its form (`IrInlineQueries.callees`): the function's component (`IrInliner.components`),
 * and 0 when no caller may splice it at all (`IrInliner.isCandidate`), else the number interned for its parameter types, which a
 * call binds its arguments to. Not its source's version: a caller whose call binds reads the callee's form next, which names
 * everything else a splice reads of it.
 */
@:nullSafety(Strict)
class IrInlineCallee {
	public final component:Int;
	public final candidate:Int;

	public function new(component:Int, candidate:Int) {
		this.component = component;
		this.candidate = candidate;
	}

	public static function same(left:IrInlineCallee, right:IrInlineCallee):Bool
		return left.component == right.component && left.candidate == right.candidate;
}

/** What an object fact's value was worked out from (`IrInlineQueries.objectFacts`). */
@:nullSafety(Strict)
class IrObjectFact {
	public final object:Null<IrObject>;
	public final subclasses:Null<Array<String>>;
	public final value:Int;

	public function new(object:Null<IrObject>, subclasses:Null<Array<String>>, value:Int) {
		this.object = object;
		this.subclasses = subclasses;
		this.value = value;
	}

	/** Whether `object` with `subclasses` is what this was worked out from, part by part. */
	public function holds(object:Null<IrObject>, subclasses:Null<Array<String>>):Bool {
		var known = this.object;
		if (known == null || object == null)
			return known == object;
		if (!compiler.ir.model.IrDeclarationEquality.sameObject(known, object))
			return false;
		var before = this.subclasses;
		if (before == null || subclasses == null)
			return before == subclasses;
		if (before.length != subclasses.length)
			return false;
		for (index in 0...before.length)
			if (before[index] != subclasses[index])
				return false;
		return true;
	}
}

/**
 * The inliner's output as the session last published it: `published` is the inlined form each function had after the last successful
 * compile, which is what a patch has to be computed against, and `instrumented` its instrumented form. What the stage reuses from one
 * build to the next is the session's database's (`IrInlineQueries`).
 */
@:nullSafety(Strict)
class IrInlineCache {
	public var published:Map<String, IrFunction> = [];

	/** Each function's instrumented form, kept while its inlined form and the scope are unchanged. */
	public var instrumented:Map<String, {source:IrFunction, scope:String, result:IrFunction}> = [];

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
			known = {fn: fn, print: compiler.ir.codec.IrFunctionStateCodec.codeFingerprint(fn)};
		nextPositionalPrints.set(fn.name, known);
		return known.print;
	}

	/** Keeps only the fingerprints this compile asked for, so a removed function's entry does not stay alive. */
	public function finishPositionalFingerprints():Void {
		positionalPrints = nextPositionalPrints;
		nextPositionalPrints = [];
	}

	public function new() {}

	/** Where the cache keeps a function that is not frozen, or null when everything it keeps is (`--check-reuse`). */
	public function unfrozen():Null<String> {
		for (f in published)
			if (IrInlineQueries.thawed(f))
				return 'published ${f.name}';
		for (entry in instrumented) {
			if (IrInlineQueries.thawed(entry.source))
				return 'instrumented source ${entry.source.name}';
			if (IrInlineQueries.thawed(entry.result))
				return 'instrumented ${entry.result.name}';
		}
		return null;
	}

	public function copy():IrInlineCache {
		// Each map is replaced as a whole by the run that changes it, never changed in place, so the copy shares them.
		var result = new IrInlineCache();
		result.published = published;
		result.instrumented = instrumented;
		result.positionalPrints = positionalPrints;
		result.positionalNatives = positionalNatives;
		return result;
	}
}

/**
 * The inliner's memo in a session (docs/design/QUERY_ENGINE.md, slice 5): by the number of a function's name, its inlined form
 * (`forms`), a computed kind of the session's database whose reads are the facts the inlining read (`IrStageFacts`, the stage's
 * space) and the forms of the callees it looked at; and, by the kind's slot, the version of the function the memo was made from
 * (`IrFunction.version`) and the function's cleaned form. A memo holds while it was made from the same function object and nothing it
 * read changed, so a callee inlined again to the same form holds its callers (early cutoff, `IrInlinedForm.same`).
 *
 * What a caller reads of a function before its form is a kind of its own (`callees`), put for every function each build.
 *
 * The copies of the session state share it, as they share the stage memos: what a rolled-back build computed is dropped with its
 * memos (`QueryDatabase.rollBack`), and a column of a slot is read only while the slot's memo is the one it was kept with.
 */
@:nullSafety(Strict)
class IrInlineQueries {
	public final forms:ComputedQueryKind<IrInlinedForm>;

	/** By the number of a function's name, what a caller reads of it before its form (`IrInlineCallee`), put each build. */
	public final callees:ComputedQueryKind<IrInlineCallee>;

	/** By slot, the version of the function the memo was made from; 0 while it is being made or for none. */
	var inputs:Array<Int> = [];

	/** By slot, the cleaned form of the function the memo was made from (`IrInliner.run`), null until the build kept it. */
	var cleaned:Array<Null<IrFunction>> = [];

	/**
	 * By object name, the object (null for one not in the program) and direct subclasses an object fact (`IrInliner.OBJECT`) last
	 * worked its value out from, and that value: an object that compares the same part by part has it again, without its text. A
	 * value is the number the session's facts interned for the text (`IrStageFacts.intern`), which no other text is ever given.
	 */
	public final objectFacts:Map<String, IrObjectFact> = [];

	public function new(database:QueryDatabase) {
		forms = database.register(new ComputedQueryKind<IrInlinedForm>("inliner", IrInlinedForm.same, null,
			key -> IrSymbol.ofFunctionKey(key).name));
		callees = database.register(new ComputedQueryKind<IrInlineCallee>("inliner-callees", IrInlineCallee.same, null,
			key -> IrSymbol.ofFunctionKey(key).name));
	}

	/**
	 * Whether the memo in `slot` was made from the function of version `input`, and its cleaned form is kept. A memo the database
	 * dropped (swept, or computed over what a rollback undid) leaves its columns behind until its slot is computed again.
	 */
	public inline function madeFrom(slot:Int, input:Int):Bool
		return slot < inputs.length && inputs[slot] == input && cleaned[slot] != null && forms.verifiedIn(slot) != 0;

	/** Starts computing the memo in `slot`: until `end` and `keepCleaned`, it is made from no function. */
	public function begin(database:QueryDatabase, slot:Int):Void {
		forms.begin(database, slot);
		if (slot < inputs.length) {
			inputs[slot] = 0;
			cleaned[slot] = null;
		}
	}

	/**
	 * Ends computing the memo in `slot` (`begin`), made from the function of version `input`, with `form`, and returns the form kept:
	 * the memo's when it is the same (early cutoff); with `walked`, a form that depends on where the walk made it, `form`, changed now.
	 */
	public function end(database:QueryDatabase, slot:Int, input:Int, form:IrInlinedForm, walked:Bool):IrInlinedForm {
		if (slot >= inputs.length) {
			QueryRead.extend(inputs, forms.capacity());
			cleaned.resize(forms.capacity());
		}
		inputs[slot] = input;
		return walked ? forms.endChanged(database, slot, form) : forms.end(database, slot, form);
	}

	/** The cleaned form kept with the memo in `slot`, made from the function it was made from (`madeFrom`). */
	public inline function cleanedOf(slot:Int):Null<IrFunction>
		return slot < cleaned.length ? cleaned[slot] : null;

	/** Keeps `fn` as the cleaned form of the memo in `slot`, ended in this build or held. */
	public inline function keepCleaned(slot:Int, fn:IrFunction):Void
		cleaned[slot] = fn;

	/** Whether `fn` has a body that is not frozen. */
	public static function thawed(fn:IrFunction):Bool {
		var body = fn.body;
		return body != null && !body.frozen;
	}

	/** Where the memo keeps a body that is not frozen, or null when everything it keeps is (`--check-reuse`). */
	public function unfrozen():Null<String> {
		for (slot in 0...cleaned.length) {
			var fn = cleaned[slot];
			if (fn != null && thawed(fn))
				return 'cleaned ${fn.name}';
			var form = fn == null || forms.verifiedIn(slot) == 0 ? null : forms.value(slot).body;
			if (form != null && !form.frozen)
				return 'inlined form ${form.name}';
		}
		return null;
	}

	/** Lets go of every memo (`IrStageMemos.clear`). */
	public function clear():Void {
		forms.clear();
		callees.clear();
		inputs = [];
		cleaned = [];
		objectFacts.clear();
	}
}

/**
 * Inlines small callees into their callers. See docs/design/INLINING_AND_VALUE_TYPES.md.
 *
 * The pass never mutates a function it was given: cached IR is shared between compiles and transaction snapshots, so a
 * caller that changes is rebuilt as a new IrFunction and unchanged callers keep their identity. Decisions depend only
 * on IR content, never on the order of `program.functions`, so an incremental build matches a clean one.
 */
@:nullSafety(Strict)
class IrInliner extends IrFactSource {
	/** Instruction budget for a callee without an `inline` hint. */
	public static inline var SmallBudget = 24;

	/** Instruction budget for a callee declared `inline`. */
	public static inline var HintBudget = 96;

	static inline var MaxBlocks = 12;
	static inline var MaxInlinesPerFunction = 48;
	static inline var MaxFunctionInstructions = 3000;
	static inline var MaxChainDepth = 24;

	/** The stage's name in the session's facts (its space), and its step of the call graph's components. */
	static inline final STAGE = "inliner";

	static inline final COMPONENTS = "inliner-components";

	// The kinds of the stage's facts (`fact`), each keyed by a name. What a function's inlining reads of the program is these, what
	// it read of the callees it looked at (`IrInlineQueries.callees`) and their forms, so its memo holds while its source is the same
	// object and none of them changed.

	/** The settings every function's inlining depends on (the key is empty). */
	static inline final SETTINGS = 0;

	/** An object's description and direct subclasses (`objectText`), by the object's name. */
	static inline final OBJECT = 1;

	/** A function's source, which copy elision reads (`pristineBody`), as its version. */
	static inline final SOURCE = 2;

	/** That a function's form depends on where the walk made it (`impure`): a value never the same, so its memo never holds. */
	static inline final IMPURE = 3;

	final profile:TargetProfile;

	/**
	 * Every function has a number, its place in the program's functions (a name has one function, the last given), and the
	 * per-function state below is indexed by it: by `IrSymbol.id`, the number of each function, -1 for a symbol that names none.
	 */
	final idsBySymbol:Array<Int> = [];

	final functions:Array<IrFunction> = [];

	/** By function id, its inlined form once inlined, null for one no caller may splice (`IrInlinedForm`); see `finished`. */
	final done:Array<Null<IrBody>> = [];

	/** By function id, whether it was inlined or its memo held in this compile. */
	final finished:Array<Bool> = [];

	/** By function id once finished, whether a caller may splice its form (`splicesForm`): 0 until worked out, 1 yes, 2 no. */
	final splices:Array<Int> = [];

	/** By function id, its slot in the session's kind of the stage (`IrInlineQueries.forms`), and in its kind of what a caller reads of it before its form (`callees`); only with a memo. */
	final slots:Array<Int> = [];

	final calleeSlots:Array<Int> = [];

	final voidType:Int;
	final receiverCheckSymbol:Int;

	/** By function id, its inlined form when that is its source's encoding, unchanged, else null. */
	final sourceBodies:Array<Null<IrBody>> = [];

	/** By function id, its source body as copy elision reads it, in a compile that keeps no session (else the source's own). */
	final pristine:Array<Null<IrBody>> = [];

	/**
	 * By function id, its cleaned-up form when it is known before `run` cleans the forms up: the memo's, when it held, or when its
	 * inlining left the source it was made from as it is again; else the cleanup of the body the inlining edited, which no memo holds
	 * (the memo has its own compacted copy, or no copy when no caller may splice it).
	 */
	final cleanedForms:Array<Null<IrFunction>> = [];

	/**
	 * By function id, what its source calls (`IrCallEdges`): the call graph's edges, and the instructions of its source body for the
	 * screen of what may be inlined after the body is edited.
	 */
	var edges:Array<IrCallEdges> = [];

	/**
	 * Whether the functions' inlining edits their source bodies in place: in a compile that keeps no session, when no source has a
	 * value copy, so copy elision, which reads callees' source bodies, never runs; else each is edited on a copy.
	 */
	var ownsSources = false;

	/** By callee value id, its value here, for one splice. */
	final calleeValues:Array<Int> = [];

	/** The rows a splice puts in place of the call. */
	final madeRows:Array<Int> = [];

	/**
	 * Copy elision's callbacks, made once. One field, set last: a method is taken as a value only once every other field is
	 * set.
	 */
	final copyElisionCallbacks:{final bodyOf:String->Null<IrBody>;
	final resolve:IrType->String->Null<String>;
	final consult:String->Void;
	};
	final impure:Array<Bool> = [];
	final visiting:Array<Bool> = [];
	final entryPoint:String;

	/** The most classes a method call's resolution looks at: the receiver's class and the classes that extend it. */
	static inline final MaxSubclassWalk = 256;

	/** The program's objects and the direct subclasses of each (for resolving a virtual call when every override agrees). */
	final table:IrObjectTable;

	/** The tables the cleanup passes reuse across functions. */
	final passScratch = new IrPassScratch();

	/** Which function each class and method resolve to, shared with the other passes that resolve calls. */
	final resolution:IrMethodResolution;

	/** The program's objects by name, and the direct subclasses of each: what an object fact describes (`OBJECT`). */
	final objects:Map<String, IrObject> = [];

	final subclasses:Map<String, Array<String>> = [];

	final cache:IrInlineCache;
	final allowInline:Bool;

	/** What every function's inlining depends on, whatever it looks at (`SETTINGS`). */
	final settings:String;

	/** The session's memos, with the stage's (`queries`) and its facts; null in a compile that keeps no session, which reuses nothing. */
	final memos:Null<IrStageMemos>;

	final queries:Null<IrInlineQueries>;
	final facts:Null<IrStageFacts>;

	/** The function being inlined, innermost last, and whether its form depends on where the walk made it. */
	final frameIds:Array<Int> = [];

	final frameImpure:Array<Bool> = [];

	/** Parallel to `frameIds`: the objects each function being inlined has consulted so far. */
	final objectFrames:Array<Map<String, Bool>> = [];

	var depth = 0;

	/**
	 * By function id, a number for its strongly connected component in the call graph of the original bodies: the lowest number of a
	 * name among its members (`IrSymbol.functionKey`), so it stays the same between compiles while that member does, which is what a
	 * caller reads of a component (`IrInlineCallee`). Inlining never goes into a call to a function of the caller's own component (a cycle):
	 * a function's inlined form then depends only on its own source and on the callees outside its component, not on where the walk
	 * happened to enter the cycle.
	 */
	var components:Array<Int> = [];

	/**
	 * The compile keeps a session: what the stage keeps is frozen, and with the session's memos it is memoized for the next compile, with
	 * what each function's inlining read. A compile that keeps no session has no next compile, so it records none of it.
	 */
	final memoizes:Bool;

	/** The compile checks its reuse (`CompileOptions.checkReuse`): a function whose memo holds is inlined again and the two results must be equal. */
	final checkingMemo:Bool;

	/** Each inlined function goes through load/store forwarding and strength reduction, as the options ask. */
	final loadStoreForwarding:Bool;

	final strengthReduction:Bool;

	function new(program:IrProgram, cache:IrInlineCache, profile:TargetProfile, options:compiler.CompileOptions,
			stageMemos:Null<IrStageMemos>) {
		this.allowInline = options.inlining;
		this.loadStoreForwarding = options.loadStoreForwarding;
		this.strengthReduction = options.strengthReduction;
		this.checkingMemo = options.checkReuse;
		this.memoizes = options.keepSession;
		var memos = memoizes ? stageMemos : null;
		this.memos = memos;
		var queries = memos == null ? null : memos.inliner();
		this.queries = queries;
		facts = memos == null ? null : memos.stageFacts;
		this.profile = profile;
		entryPoint = program.entryPoint;
		this.cache = cache;
		voidType = IrTypeIds.id(Void);
		receiverCheckSymbol = IrReceiverCheck.symbol();
		for (fn in program.functions) {
			var symbol = fn.symbol;
			while (idsBySymbol.length <= symbol.id)
				idsBySymbol.push(-1);
			var known = idsBySymbol[symbol.id];
			if (known >= 0) {
				functions[known] = fn;
				continue;
			}
			idsBySymbol[symbol.id] = functions.length;
			functions.push(fn);
			done.push(null);
			finished.push(false);
			splices.push(0);
			pristine.push(null);
			cleanedForms.push(null);
			sourceBodies.push(null);
			impure.push(false);
			visiting.push(false);
		}
		if (queries != null) {
			var kind = queries.forms;
			kind.reserve(functions.length, IrSymbol.functionKeysGiven());
			for (fn in functions)
				slots.push(kind.slotFor(fn.symbol.functionKey()));
		}
		// What every function's inlining depends on whatever it looks at. Each object's own description is not here: a memo records
		// the objects it consulted (`OBJECT`), so a change to one object does not invalidate the rest.
		settings = [
			entryPoint,
			"profile=" + profile.key(),
			"inline=" + allowInline,
			"loadstore=" + loadStoreForwarding,
			"strength=" + strengthReduction
		].join(";");
		for (object in program.objects) {
			objects.set(object.name, object);
			if (object.base != null) {
				var base = Std.string(object.base), children = subclasses.get(base);
				if (children == null)
					subclasses.set(base, children = []);
				children.push(object.name);
			}
		}
		table = new IrObjectTable(objects, subclasses);
		resolution = IrMethodResolution.of(program);
		copyElisionCallbacks = {bodyOf: pristineBody, resolve: resolveMethod, consult: consultName};
		computeComponents(program);
		var known = facts;
		if (memos != null && known != null && queries != null) {
			known.run(memos.database, STAGE, this);
			putCallees(memos.database, queries.callees, known);
		}
	}

	/** Puts what a caller reads of each function before its form (`IrInlineQueries.callees`), as this compile has it. */
	function putCallees(database:QueryDatabase, kind:ComputedQueryKind<IrInlineCallee>, table:IrStageFacts):Void {
		kind.reserve(functions.length, IrSymbol.functionKeysGiven());
		for (id in 0...functions.length) {
			var key = functions[id].symbol.functionKey(),
				component = components[id],
				candidate = isCandidate(id) ? parametersValue(id, table) : 0,
				kept = kind.kept(key);
			calleeSlots.push(kind.slotFor(key));
			kind.put(database, key, kept != null && kept.component == component
				&& kept.candidate == candidate ? kept : new IrInlineCallee(component,
				candidate));
		}
	}

	/**
	 * The call graph's components (`components`), from what each function's source calls (`edges`). In a session they are a step of
	 * its database (`IrWalkMemo`) whose summary of a function is its calls, kept while the program's functions and objects and what
	 * each function calls are as they were, so only an edit that changes a call works them out again.
	 */
	function computeComponents(program:IrProgram):Void {
		var memos = this.memos;
		if (memos == null) {
			var copies = false;
			for (fn in functions) {
				var record = IrCallEdges.read(sourceBody(fn));
				if (record.copies)
					copies = true;
				edges.push(record);
			}
			ownsSources = !memoizes && !copies;
			components = strongComponents();
			return;
		}
		var step:compiler.ir.reuse.IrWalkMemo<IrCallEdges, Array<Int>> = memos.step(COMPONENTS, IrCallEdges.sameCalls),
			read = callEdges,
			kept = step.kept(memos.database, program, functions, [], [], read);
		for (fn in functions) {
			var record = step.settledSummary(fn.symbol.functionKey(), fn);
			edges.push(record != null ? record : read(fn));
		}
		if (kept != null && !checkingMemo) {
			components = kept;
			return;
		}
		step.begin(memos.database);
		for (fn in functions)
			step.summary(fn);
		var made = strongComponents();
		if (kept != null && kept.join(",") != made.join(","))
			throw new InternalError("--check-reuse: the inliner's components differ from its call graph's");
		step.end(memos.database, made);
		components = made;
	}

	/** What `fn`'s source calls. */
	function callEdges(fn:IrFunction):IrCallEdges
		return IrCallEdges.read(sourceBody(fn));

	/** Tarjan's algorithm over the call edges of the original bodies: each function's component, numbered as `components` says. */
	function strongComponents():Array<Int> {
		var count = functions.length, targets:Array<Array<Int>> = [], memos = this.memos;
		for (id in 0...count) {
			var calls:Array<Int> = [], record = edges[id];
			for (site in record.sites)
				if (site >= 0) {
					var target = functionId(site);
					if (target >= 0)
						calls.push(target);
				} else {
					var method = -site - 1,
						callee = resolveMethod(record.receivers[method], record.methods[method]),
						target = callee == null ? -1 : idOfName(callee);
					if (target >= 0)
						calls.push(target);
				}
			targets.push(calls);
		}
		var order:Array<Int> = [for (_ in 0...count) -1],
			low:Array<Int> = [for (_ in 0...count) 0],
			onStack:Array<Bool> = [for (_ in 0...count) false],
			labels:Array<Int> = [for (_ in 0...count) 0],
			stack:Array<Int> = [],
			members:Array<Int> = [],
			counter = 0;
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
					calls = targets[node];
				if (cursor < calls.length) {
					cursors[cursors.length - 1] = cursor + 1;
					var next = calls[cursor];
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
						var member:Int, label = -1;
						members.resize(0);
						do {
							var popped = stack.pop();
							if (popped == null)
								throw new InternalError("Strongly connected component stack emptied before its root");
							member = popped;
							onStack[member] = false;
							members.push(member);
							var key = memos != null ? functions[member].symbol.functionKey() : member;
							if (label < 0 || key < label)
								label = key;
						} while (member != node);
						for (each in members)
							labels[each] = label;
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
		return labels;
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

	/** What an object fact says of `name`: its description and its direct subclasses; an object not in the program has its own. */
	function objectText(name:String):String {
		var object = objects.get(name);
		if (object == null)
			return "absent " + name;
		var text = describe(object), children = subclasses.get(name);
		if (children != null) {
			var sorted = children.copy();
			sorted.sort(Reflect.compare);
			text += ">" + sorted.join(",");
		}
		return text;
	}

	/**
	 * Inlines `program`'s functions as `options` ask (the defaults, without them: every pass on, no reuse checks), replaces every
	 * function that had a call inlined and returns the names whose inlined form differs from the one published by the previous
	 * compile. Those functions must be re-lowered and patched even when their own source did not change, because a callee they
	 * inlined did. With `stageMemos`, in a compile that keeps a session, a function whose memo holds (`IrInlineQueries`) is not
	 * inlined again: its forms are the memo's.
	 *
	 * The stage runs on bodies (docs/design/IR_CORE_COLUMNS.md): each function is encoded when it is first inlined, inlined,
	 * forwarded, reduced and cleaned up in place, and frozen at the end: `program.functions` holds each as its body
	 * (`IrFunction.ofBody`), which the HashLink lowering reads, decoded only for what still reads objects.
	 */
	public static function run(program:IrProgram, cache:IrInlineCache, profile:TargetProfile,
			?options:compiler.CompileOptions,
			?instrument:IrInstrumentationScope, ?stageMemos:IrStageMemos):Array<String> {
		var settings = options == null ? new compiler.CompileOptions() : options;
		var inliner = new IrInliner(program, cache, profile, settings, stageMemos),
			functions:Array<IrFunction> = [],
			changed:Array<String> = [];
		var published:Map<String, IrFunction> = [],
			instrumented:Map<String, {source:IrFunction, scope:String, result:IrFunction}> = [];
		// Every function is inlined before any is cleaned up: a caller inlines a callee's form before its cleanup, which edits it.
		var inlinedForms = [for (fn in program.functions) inliner.inlinedVersion(inliner.functionId(fn.symbol.id))];
		for (index in 0...program.functions.length) {
			var fn = program.functions[index],
				inlined = inlinedForms[index],
				id = inliner.functionId(fn.symbol.id),
				result:IrFunction;
			// Keep inlining decisions based on the original post-inline bodies. Removing dead values in a memoized callee
			// would otherwise change the caller's budget and can introduce new allocations through a different expansion.
			var early = inliner.cleanedForms[id];
			if (early != null)
				result = early;
			else if (inlined != null)
				result = inliner.cleanUp(fn, inlined);
			else
				throw new InternalError('The inline memo of ${fn.name} keeps neither its inlined form nor its cleaned one');
			var cleaned = result;
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
				// Generated functions (initializers, the entry) are rebuilt on every compile; only different code counts.
				if (IrFunctionStateEquality.same(previous, result)) {
					result = previous;
					// The next compile then finds the published form itself and compares nothing.
					if (instrument == null)
						cleaned = previous;
				} else
					changed.push(fn.name);
			} else if (previous == null)
				changed.push(fn.name);
			inliner.keepCleaned(id, cleaned);
			functions.push(result);
			published.set(fn.name, result);
			var instrumentedEntry = instrument == null ? null : instrumented.get(fn.name);
			if (instrumentedEntry != null)
				instrumentedEntry.result = result;
		}
		program.functions = functions;
		// A compile that keeps no session reads the stage's output as bodies only (a session compares and caches the objects), so
		// once no callee is looked at any more an unchanged source keeps only its body.
		if (!inliner.memoizes)
			for (fn in functions)
				if (fn.body != null)
					fn.releaseDecoded();
		IrOpportunityCensus.report(program, inliner.allowInline);
		cache.published = published;
		cache.instrumented = instrumented;
		return changed;
	}

	/** The number of the function whose symbol is `symbol`, or -1. */
	inline function functionId(symbol:Int):Int
		return symbol < idsBySymbol.length ? idsBySymbol[symbol] : -1;

	/** The number of the function named `name`, or -1 for a name no function of the program has. */
	function idOfName(name:String):Int {
		var symbol = IrSymbol.known(name);
		return symbol == null ? -1 : functionId(symbol.id);
	}

	/** The number of the function whose name's number is `key` (`IrSymbol.functionKey`), or -1. */
	inline function idOfKey(key:Int):Int
		return functionId(IrSymbol.ofFunctionKey(key).id);

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
		var id = functionId(fn.symbol.id);
		if (id >= 0 && sourceBodies[id] == inlined && body.edits == before) {
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
	 * `fn`'s body as the stages before this one left it, frozen in a session, which keeps it: the one it has
	 * (docs/design/IR_CORE_COLUMNS.md, the conversion point is before this stage), else its encoding, which it then keeps.
	 */
	function sourceBody(fn:IrFunction):IrBody {
		var body = fn.encodedBody(passScratch.bodyBuilder);
		return memoizes ? fn.freezeBody(passScratch.bodyBuilder) : body;
	}

	/** The body function `id`'s inlining edits: its source's, when the inliner owns it (`ownsSources`), else a copy of it. */
	function workingBody(id:Int):IrBody {
		var source = sourceBody(functions[id]);
		if (memoizes)
			return source.thaw(passScratch.bodyBuilder);
		return ownsSources ? source.forEditing(passScratch.bodyBuilder) : source.thaw(passScratch.bodyBuilder);
	}

	/** The source body of the function named `name` (null for none), as copy elision reads its callees. */
	function pristineBody(name:String):Null<IrBody> {
		var id = idOfName(name);
		if (id < 0)
			return null;
		if (memoizes)
			return sourceBody(functions[id]);
		if (ownsSources)
			throw new InternalError('Copy elision read the source body of $name, which the inliner edits in place');
		var known = pristine[id];
		if (known == null) {
			known = sourceBody(functions[id]);
			pristine[id] = known;
		}
		return known;
	}

	/** Records a function copy elision consulted in the function being inlined: its source (`SOURCE`). */
	function consultName(name:String):Void
		if (recording() && idOfName(name) >= 0)
			read(SOURCE, name);

	/** Whether what the inlining under way reads is recorded: a session's, with a function being inlined. */
	inline function recording():Bool
		return queries != null && frameIds.length > 0;

	/** The value of the stage's fact of `kind` about `key`, recorded as a read of the memo being computed (`IrStageFacts`). */
	function read(kind:Int, key:String):Int {
		var table = facts, memos = this.memos;
		if (table == null || memos == null)
			throw new InternalError('The inliner read its fact $kind of $key without a memo');
		return table.read(memos.database, table.id(space, kind, key));
	}

	/** The value of the stage's fact of `kind` about `key`, as the program stands in this compile (`IrStageFacts`). */
	override public function fact(kind:Int, key:String):Int {
		var table = facts, queries = this.queries;
		if (table == null || queries == null)
			throw new InternalError('The inliner worked its fact $kind of $key out without a memo');
		if (kind == SETTINGS)
			return table.intern(settings);
		if (kind == OBJECT) {
			var object = objects.get(key), children = subclasses.get(key), known = queries.objectFacts.get(key);
			if (known != null && known.holds(object, children))
				return known.value;
			var value = table.intern(objectText(key));
			queries.objectFacts.set(key, new IrObjectFact(object, children, value));
			return value;
		}
		if (kind == IMPURE)
			return IrStageFacts.UNKNOWN;
		// A function the program no longer has: what read a fact of it does not hold.
		var id = idOfName(key);
		if (id < 0)
			return IrStageFacts.UNKNOWN;
		if (kind == SOURCE)
			return functions[id].version;
		throw new InternalError('The inliner has no fact of kind $kind');
	}

	/** The number `table` interns for function `id`'s parameter types: worked out once for what its source calls (`IrCallEdges`). */
	function parametersValue(id:Int, table:IrStageFacts):Int {
		var record = edges[id];
		if (record.parameters == 0)
			record.parameters = table.intern("parameters "
				+ IrTypeIdentity.listText([for (argument in functions[id].arguments) argument.type]));
		return record.parameters;
	}

	/** Whether a caller may splice the inlined form of function `id`, which is finished. */
	function splicesForm(id:Int):Bool {
		var known = splices[id];
		if (known == 0) {
			var form = done[id];
			known = form != null && spliceableForm(form) ? 1 : 2;
			splices[id] = known;
		}
		return known == 1;
	}

	/**
	 * Whether a caller may splice `form`, an inlined form: it fits the budget, and is straight-line or marked inline (HashLink's
	 * JIT keeps registers only inside a basic block, so a branching body costs more spliced in than called).
	 */
	public static function spliceableForm(form:IrBody):Bool
		return fits(form) && (isStraightLine(form) || form.inlineHint);

	/** Whether function `id` may be spliced at all, by its name and its source alone. */
	inline function isCandidate(id:Int):Bool
		return edges[id].candidate && functions[id].name != entryPoint;

	/**
	 * Whether the memo of function `id` holds in this compile: made from the same version of its source, and nothing it read changed.
	 * The callees whose forms it read are brought up to date first, so its verification reads each of them as this compile has it,
	 * and a callee inlined again to the same form holds it; a memo that read of a function the program no longer has, or the form of
	 * one being inlined now (a cycle the last compile's reads lead through), does not hold.
	 */
	function holds(queries:IrInlineQueries, id:Int):Bool {
		var slot = slots[id], kind = queries.forms, callees = queries.callees, memos = this.memos;
		if (memos == null || !queries.madeFrom(slot, functions[id].version))
			return false;
		visiting[id] = true;
		var ready = true;
		for (position in 0...kind.readsMade(slot)) {
			var read = kind.readMade(slot, position), of = QueryRead.kind(read);
			if (of == callees.index) {
				// A function the program no longer has, whose key this compile did not put.
				var key = callees.keyOf(QueryRead.key(read));
				if (key < 0 || idOfKey(key) < 0) {
					ready = false;
					break;
				}
				continue;
			}
			if (of != kind.index)
				continue;
			var key = kind.keyOf(QueryRead.key(read)), callee = key < 0 ? -1 : idOfKey(key);
			if (callee < 0 || visiting[callee]) {
				ready = false;
				break;
			}
			inlinedVersion(callee);
		}
		visiting[id] = false;
		return ready && kind.current(memos.database, slot);
	}

	/** Takes the memo of function `id`, which holds, as its forms in this compile. */
	function take(queries:IrInlineQueries, id:Int):Void {
		var slot = slots[id], kept = queries.forms.value(slot);
		done[id] = kept.body;
		finished[id] = true;
		splices[id] = kept.splices ? 1 : 2;
		cleanedForms[id] = queries.cleanedOf(slot);
	}

	/** Keeps `cleaned` as the cleaned form of function `id`'s memo, for the next compile. */
	function keepCleaned(id:Int, cleaned:IrFunction):Void {
		var queries = this.queries;
		if (queries != null)
			queries.keepCleaned(slots[id], cleaned);
	}

	/** Function `id`'s inlined form, null when no caller may splice it (`IrInlinedForm`). */
	function inlinedVersion(id:Int):Null<IrBody> {
		if (finished[id])
			return done[id];
		var queries = this.queries, memos = this.memos, original = functions[id], name = original.name;
		var held = queries != null && holds(queries, id);
		if (queries != null && held && !checkingMemo) {
			take(queries, id);
			return done[id];
		}
		var slot = queries == null ? -1 : slots[id];
		// The cleaned form kept with a memo made from this source, which its inlining left as it was: when the inlining leaves it as it
		// is again, the cleaned form is this compile's too.
		var lastCleaned = queries == null || held || !queries.madeFrom(slot, original.version)
			|| queries.forms.value(slot).body != sourceBody(original) ? null : queries.cleanedOf(slot);
		visiting[id] = true;
		depth++;
		frameIds.push(id);
		frameImpure.push(false);
		var consultedObjects:Map<String, Bool> = [];
		if (queries != null && memos != null) {
			if (held)
				queries.forms.begin(memos.database, slot);
			else
				queries.begin(memos.database, slot);
			read(SETTINGS, "");
		}
		if (memoizes) {
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

		// The memo holds the result as it is, when a caller may splice it. Without a memo, callers inline the result as it is and
		// the final cleanup, which runs once every function is inlined, edits it in place.
		var unchanged = body.edits == before;
		var result:Null<IrBody> = if (!memoizes)
			body;
		else if (unchanged)
			sourceBody(original);
		else if (looksInlinable(id) && fits(body))
			body.freeze(memoizes, passScratch.bodyBuilder);
		else
			null;

		var isImpure = frameImpure.pop() == true;
		if (queries != null) {
			for (objectName in consultedObjects.keys())
				read(OBJECT, objectName);
			if (isImpure)
				read(IMPURE, name);
		}
		frameIds.pop();
		depth--;
		visiting[id] = false;
		if (!memoizes) {
			done[id] = result;
			finished[id] = true;
			sourceBodies[id] = unchanged ? result : null;
			return result;
		}
		objectFrames.pop();
		table.consulted = objectFrames.length > 0 ? objectFrames[objectFrames.length - 1] : null;
		var form = result == null ? IrInlinedForm.NONE : new IrInlinedForm(result);
		if (queries != null && memos != null) {
			if (held) {
				// What the memo holds is what callers read of the form and the function's cleaned form, which a function no caller
				// may splice is all there is of.
				queries.forms.cancel(memos.database, slot);
				if (!IrInlinedForm.same(queries.forms.value(slot), form))
					throw new InternalError('--check-reuse: the inlined form of $name differs from the one its memo holds');
				var cleaned = unchanged ? cleanUp(original, sourceBody(original)) : result != null ? cleanUp(original,
					result,
					body) : cleanUp(original, body),
					kept = queries.cleanedOf(slot);
				if (kept == null || !IrFunctionStateEquality.same(kept, cleaned))
					throw new InternalError('--check-reuse: the cleaned form of $name differs from the one its memo holds');
				take(queries, id);
				return done[id];
			}
			queries.end(memos.database, slot, original.version, form, isImpure);
		}
		done[id] = result;
		finished[id] = true;
		splices[id] = form.splices ? 1 : 2;
		sourceBodies[id] = result != null && result == sourceBody(original) ? result : null;
		// A form no caller splices is cleaned up now, in place: the memo keeps no copy of it.
		if (!unchanged)
			cleanedForms[id] = result != null ? cleanUp(original, result, body) : cleanUp(original, body);
		else if (lastCleaned != null)
			cleanedForms[id] = lastCleaned;
		if (isImpure)
			impure[id] = true;
		return result;
	}

	/** Records that the inlining under way read what a caller reads of function `id` before its form (`IrInlineQueries.callees`). */
	inline function readCallee(id:Int):Void {
		var queries = this.queries, memos = this.memos;
		if (recording() && queries != null && memos != null)
			memos.database.record(queries.callees, calleeSlots[id]);
	}

	/** Whether the functions `caller` and `callee` are in one component, as the caller's inlining reads it. */
	function sameComponent(caller:Int, callee:Int):Bool {
		readCallee(caller);
		readCallee(callee);
		return components[caller] == components[callee];
	}

	/** The inlined form of the function the call at `row` resolves to, when it can be inlined there, else null. */
	function calleeOf(body:IrBody, row:Int):Null<IrBody> {
		// A method call's actuals are its receiver, then its arguments: its operands, as a call's are its arguments.
		var id = -1;
		switch body.opcode(row) {
			case IrOpcode.Call:
				id = functionId(body.aux(row));
			case IrOpcode.MethodCall:
				var target = resolveMethod(body.valueType(body.operand(row, 0)), IrSymbol.at(body.aux(row) >> 1).name);
				if (target != null)
					id = idOfName(target);
			default:
		}
		if (id < 0)
			return null;
		var original = functions[id];
		// A call into the caller's own cycle is never inlined (see `components`); this covers recursion and every ancestor of the walk.
		if (frameIds.length > 0 && sameComponent(frameIds[frameIds.length - 1], id))
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
		// What the caller reads of the callee: whether it may be spliced (its source, while it may), then the form it splices.
		var count = body.operandCount(row);
		readCallee(id);
		if (!isCandidate(id) || original.arguments.length != count)
			return null;
		for (index in 0...count)
			if (!bindable(body.valueType(body.operand(row, index)), original.arguments[index].type))
				return null;
		var candidate = inlinedVersion(id), queries = this.queries, memos = this.memos;
		if (recording() && queries != null && memos != null)
			memos.database.record(queries.forms, slots[id]);
		return candidate != null && splicesForm(id) ? candidate : null;
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
	inline function looksInlinable(id:Int):Bool
		return edges[id].inlinable && functions[id].name != entryPoint;

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
							table.get(compiler.ir.model.IrTypeTools.valueObjectName(body.valueType(body.output(row))));
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
			nextBlock = passScratch.callExpansion.expand(body, index, call, callee, nextBlock,
				needsReceiverCheck(body, call));
			// Continue with the first inlined block; calls left in it were not candidates.
			index++;
		}
		body.sweepAliases();
		IrScalarReplacement.runBody(body, table, passScratch, false, profile.packedValueFields);
		var callbacks = copyElisionCallbacks;
		IrCopyElision.runBody(body, callbacks.bodyOf, callbacks.resolve, callbacks.consult, passScratch);
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

	/**
	 * Replaces the call at row `call` of block `block` (an index) by the straight-line callee's rows, values renamed: its
	 * receiver check and upcasts, its instructions, and a `ConstVoid` for a void call; otherwise the call's output stands for
	 * the value the callee returned (an alias, swept after the last call is inlined).
	 */
	function spliceCall(body:IrBody, block:Int, call:Int, callee:IrBody):Void {
		var where = body.provenance(call), output = body.output(call), rows = madeRows;
		rows.resize(0);
		var values = IrPassScratch.filledInts(calleeValues, callee.valueLimit(), -1);
		if (needsReceiverCheck(body, call)) {
			var checked = body.newValue("$receiver-check", voidType);
			body.beginRow();
			body.pushOperand(body.resolve(body.operand(call, 0)));
			rows.push(body.endRow(IrOpcode.Call, checked, receiverCheckSymbol, where));
		}
		passScratch.callExpansion.bindArgumentValues(body, call, callee, values, rows, where, true);
		var terminator = callee.terminatorRow(0), row = callee.firstRow(0);
		while (row >= 0 && row != terminator) {
			IrBodyCallExpansion.defineCalleeValue(body, callee, row, values);
			row = callee.nextRow(row);
		}
		row = callee.firstRow(0);
		while (row >= 0 && row != terminator) {
			rows.push(body.copyRow(callee, row, values));
			row = callee.nextRow(row);
		}
		if (terminator < 0 || callee.opcode(terminator) != IrOpcode.Return)
			throw new InternalError("A straight-line callee must return");
		var returned = IrBodyCallExpansion.calleeValue(values, callee.operand(terminator, 0));
		if (body.valueTypeId(output) == voidType) {
			body.beginRow();
			rows.push(body.endRow(IrOpcode.ConstVoid, output, 0, where));
		} else
			body.alias(output, returned);
		for (made in rows)
			body.linkBefore(block, call, made);
		body.removeRow(block, call);
	}

	/** Whether a caller's argument can stand for a callee's parameter: the same type, or an object where its base class is taken. */
	static function bindable(actual:IrType, formal:IrType):Bool
		return IrVerifier.sameType(actual, formal) || switch [actual, formal] {
			case [Obj(_), Obj(_)]: true;
			default: false;
		};

	static function resolve(value:IrValue, substitutions:Map<Int, IrValue>):IrValue {
		var current = value, steps = 0;
		while (steps < 4096) {
			var next = substitutions.get(current.id);
			if (next == null)
				break;
			current = next;
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
				anchor: binding.anchor,
				scopeStart: binding.scopeStart,
				scopeEnd: binding.scopeEnd
			} : binding];
	}

	/** The instruction with every value (inputs and outputs alike) passed through `use` and every block id through `block`. */
	public static function remap(instruction:IrInstruction, use:IrValue->IrValue, block:Int->Int):IrInstruction {
		return switch instruction {
			case Phi(out, inputs): Phi(use(out), [for (input in inputs) {
				block: block(input.block), value: use(input.value)
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

/**
 * What one function's source calls, for the inliner's call graph (`IrInliner.computeComponents`): its calls in row order, each the
 * callee's symbol id, or for a method call `-(index + 1)` into the receivers and methods; its size, whether it has a value copy,
 * and whether it may be inlined at all by its name and size. It depends on the function alone, so a session keeps it while it is given the same function (the components' step,
 * `IrWalkMemo`).
 */
@:nullSafety(Strict)
class IrCallEdges {
	public final sites:Array<Int> = [];
	public final receivers:Array<IrType> = [];
	public final methods:Array<String> = [];
	public var size(default, null) = 0;
	public var copies(default, null) = false;

	/**
	 * Whether the function looks small enough to inline by its name and its source alone (`IrInliner.looksInlinable`), and may be
	 * spliced at all, as no dispatch or adapter entry is (`IrInliner.isCandidate`); neither counts the program's entry point.
	 */
	public var inlinable(default, null) = false;

	public var candidate(default, null) = false;

	/** The number interned for the function's parameter types (`IrInliner.parametersValue`), worked out once; 0 until then. */
	public var parameters = 0;

	function new() {}

	public static function read(body:IrBody):IrCallEdges {
		var edges = new IrCallEdges(), name = body.name;
		edges.size = body.instructionCount();
		edges.inlinable = !StringTools.startsWith(name, "__")
			&& edges.size <= (body.inlineHint ? IrInliner.HintBudget : IrInliner.SmallBudget) * 2;
		edges.candidate = edges.inlinable && !IrTypedInterfaceDispatch.isDispatchEntry(name)
			&& !IrTypedInterfaceDispatch.isAdapterEntry(name);
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				switch body.opcode(row) {
					case IrOpcode.ValueInit if (!edges.copies && IrCopyElision.isValueCopyRow(body, row)):
						edges.copies = true;
					case IrOpcode.Call:
						edges.sites.push(body.aux(row));
					case IrOpcode.MethodCall:
						edges.sites.push(-edges.receivers.length - 1);
						edges.receivers.push(body.valueType(body.operand(row, 0)));
						edges.methods.push(body.symbol(row).name);
					default:
				}
				row = body.nextRow(row);
			}
		}
		return edges;
	}

	/**
	 * Whether `other` names the same calls, which is all the call graph's components are worked out from (the components' step
	 * compares a function's summaries by it); the size and copies are read from the summary each build settles.
	 */
	public static function sameCalls(left:IrCallEdges, right:IrCallEdges):Bool {
		if (left.sites.length != right.sites.length || left.methods.length != right.methods.length)
			return false;
		for (index in 0...left.sites.length)
			if (left.sites[index] != right.sites[index])
				return false;
		for (index in 0...left.methods.length)
			if (left.methods[index] != right.methods[index]
				|| !IrVerifier.sameType(left.receivers[index], right.receivers[index]))
				return false;
		return true;
	}
}
