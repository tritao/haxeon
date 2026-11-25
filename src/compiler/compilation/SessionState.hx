package compiler.compilation;

import compiler.abi.RuntimeAbi.RuntimeAbiDescriptor;
import compiler.core.QualifiedName;
import compiler.core.Source.SourceSpan;
import compiler.ir.codec.IrFunctionStateEquality;
import compiler.ir.model.Ir.IrObject;
import compiler.ir.model.IrDeclarationEquality;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrSymbol;
import compiler.ir.passes.inlining.IrInliner.IrInlineCache;
import compiler.ir.pipeline.StaticInitializationOrder.IrStaticReferences;
import compiler.ir.verify.IrVerifyMemo;
import compiler.modules.ModuleState;
import compiler.query.ComputedQueryKind;
import compiler.query.QueryDatabase;
import compiler.semantic.DeclarationOwners;
import compiler.semantic.GenericSpecializationRegistry;
import compiler.semantic.ModuleCanonicalizer;
import compiler.semantic.SemanticProgram;
import compiler.semantic.SemanticWorkspace;
import compiler.syntax.TokenTable;
import compiler.types.TypeRegistry;
import compiler.types.TypedAst.TypedField;
import compiler.types.TypedAst.TypedProgram;
import haxe.io.Bytes;

/** The modules an entry reached in its last build, with what each depended on then. */
typedef ReachabilityCache = {
	final names:Array<String>;
	final dependencyKeys:Map<String, String>;
	final initializationClasses:Array<String>;
}

/**
 * Everything a build owns: the modules and what was derived from them, the types, the caches that define "the previous build" and
 * the backend. A build works on a copy (`copyForCandidate`), which the compiler takes on success; the state it was copied from is
 * left as it was, so it is the snapshot a rejected publication returns to.
 */
class SessionState {
	public final modules:Map<String, ModuleState> = [];

	/** Cross-module resolution over `modules`. */
	public final semanticWorkspace:SemanticWorkspace;

	public var types(default, null):TypeRegistry;
	public var genericSpecializations(default, null):GenericSpecializationRegistry;
	/**
	 * The program's objects by name: those of the classes and structures this build typed, and those an earlier build made for a
	 * function it typed (its closures' environments), which a function not typed again still names. A copy has its own, as a build
	 * removes the objects of the functions it types again.
	 */
	public var objects(default, null):Map<String, IrObject> = [];

	/** The order of the functions the last assembly started from; every copy shares it, as it is a function of their names. */
	public final assemblyOrder:FrontendCompilation.AssemblyOrder;

	/** Last successfully assembled typed program; failed edits never replace it. */
	public var lastTypedProgram:Null<TypedProgram> = null;

	public var semanticProgram:Null<SemanticProgram> = null;

	/** The purity and no-return facts of the last canonical program (`SemanticAssembly`), while it is made of the same modules. */
	public var programFacts:Null<compiler.semantic.ProgramFacts.InferredProgramFacts> = null;

	/**
	 * The session's query database (`docs/design/QUERY_ENGINE.md`): the build inputs, the facts typed units read and what each
	 * unit read. Every copy shares it, as an input is set outside builds and a print only moves forward; the units' records are
	 * written in a transaction the state taken from the build commits (`committed`).
	 */
	public var queries(default, null):QueryDatabase;

	/**
	 * The database commit this state was taken at (`Compiler.adoptCandidate`): the units' records that go with its modules. A
	 * build started from it rolls the records back to it first, undoing what a build that was not taken, or a state the session
	 * left (a rejected publication), wrote.
	 */
	public var committed = 0;

	/** The facts typed units read (`DeclarationFacts`), the database's first kind. */
	public var declarationFacts(default, null):compiler.semantic.DeclarationFacts;

	/** What the builds are made from, as the database's inputs (`BuildInputs`). */
	public var inputs(default, null):BuildInputs;
	public var publishedAbi:Null<RuntimeAbiDescriptor> = null;
	public var compiledOnce = false;

	/** The functions of a resumed live module, as it was published, until the first build replaces them. */
	public var rehydrationBaseline:Null<Map<String, Bytes>> = null;

	public var inlineCache(default, null):IrInlineCache = new IrInlineCache();

	/**
	 * The IR of each function the assembly starts from, by its name's symbol (`IrSymbol`), in the session's database: what the
	 * generator made of each typed function (`FrontendCompilation.publishFunctions`) and the functions the frontend and the
	 * assembler make (`IrLineage.start`). An IR made again the same keeps last build's object and the revision it changed at, so
	 * whatever reads it holds. Every copy shares it: a function's IR is put again every build it is read in, from the modules of
	 * the state the build started from.
	 */
	public var irGeneration(default, null):ComputedQueryKind<IrFunction>;

	/**
	 * Each object of the program (`objects`) by its name's symbol, put every build: one made again the same is last build's, so
	 * what compares objects downstream finds the same object, and a structure's printer, which reads its object here, is kept.
	 */
	public var irObjects(default, null):ComputedQueryKind<IrObject>;

	/**
	 * What each boot function (`IrProgramAssembler.staticInitializersFrom`) is made from, the typed fields it initializes, by the
	 * function's key: the same while each field is the same object, which it is while its initializer's unit is current.
	 */
	public var initializerInputs(default,
		null):ComputedQueryKind<Array<TypedField>>;

	/**
	 * What the assembly stages before the encode point made of each function (`IrStageMemos`), keyed on the versions of their
	 * input; every copy shares it, as an entry holds only for the versions and fact prints it recorded.
	 */
	public var stageMemos(default, null):compiler.ir.reuse.IrStageMemo.IrStageMemos;

	/**
	 * What each function of `irGeneration` names of classes and enums (`FrontendCompilation.typeMentions`), by the same key: it
	 * holds while the function does. Every copy shares it, as `irGeneration`.
	 */
	public var irTypeMentions(default, null):ComputedQueryKind<FrontendCompilation.TypeMentions>;

	/** The functions each function of `irGeneration` calls (`FrontendCompilation.callsIn`), as `irTypeMentions`. */
	public var irCalls(default, null):ComputedQueryKind<Array<String>>;

	/** What each function of `irGeneration` references for the static initialization order, as `irTypeMentions`. */
	public var staticReferences(default, null):ComputedQueryKind<IrStaticReferences>;

	/**
	 * What the last successful plain build made its final IR and module from (see `PipelineSnapshot`). A build whose inputs are equal
	 * reuses both.
	 */
	public var pipelineSnapshot:Null<PipelineSnapshot> = null;

	/**
	 * The backend of this session (`BackendSession`): what turns the final IR into the artifact, with the state it keeps between
	 * builds (the HashLink assembler and lowered functions).
	 */
	public var backend:BackendSession;

	/**
	 * What the last verification of the final IR accepted (see `IrVerifyMemo`). It belongs to the IR, not to a backend, so it is not
	 * part of the lowered-function cache. Copies share it: an acceptance holds only while the IR and everything it read are equal, so a
	 * build that fails leaves nothing wrong behind.
	 */
	public var verifyMemo(default, null):IrVerifyMemo = new IrVerifyMemo();

	public var reachabilityCache(default, null):Map<String, ReachabilityCache> = [];
	public var declarationOwners(default, null):DeclarationOwners = new DeclarationOwners();

	/**
	 * Releases what only a next build would reuse, for a compile that keeps no session (`CompileOptions.keepSession`), before its
	 * backend: the modules' tokens, syntax trees, semantic models, typed and IR bodies and canonical declarations, the pipeline
	 * snapshot, the typed and semantic programs and the caches. Diagnostics and warnings stay. The modules are changed in place, even
	 * where the state they were copied from shares them: such a compile never returns to that state.
	 */
	public function releaseRetained():Void {
		releaseSyntax();
		releaseGeneratedIr();
		for (state in modules)
			state.typedFunctions = [];
		objects = [];
		lastTypedProgram = null;
		semanticProgram = null;
		programFacts = null;
		inlineCache = new IrInlineCache();
		stageMemos = new compiler.ir.reuse.IrStageMemo.IrStageMemos(queries, irGeneration);
		pipelineSnapshot = null;
		verifyMemo = new IrVerifyMemo();
		reachabilityCache = [];
	}

	/**
	 * Releases the modules' generated IR functions, for a compile that keeps no session once its IR pipeline has its input: the
	 * passes then hold the only copy of the program. The memos keyed by those functions are emptied with them, as their keys would
	 * keep the functions alive, and so are the printers and boot functions kept with their inputs. Changes the modules and the
	 * memos in place, as `releaseRetained` does.
	 */
	public function releaseGeneratedIr():Void {
		for (state in modules)
			state.irFunctions = [];
		irGeneration.clear();
		irObjects.clear();
		initializerInputs.clear();
		irTypeMentions.clear();
		irCalls.clear();
		staticReferences.clear();
	}

	/**
	 * Releases the modules' tokens, syntax trees, semantic models and canonical declarations, for a compile that keeps no session
	 * once typing is done: the IR is assembled from the typed program. Changes the modules in place, as `releaseRetained` does.
	 */
	public function releaseSyntax():Void
		for (state in modules) {
			state.tokens = TokenTable.empty;
			state.ast = null;
			state.recoveredAst = null;
			state.recoveredTokens = TokenTable.empty;
			state.recoveredSemanticModel = null;
			state.semanticModel = null;
			state.lastGoodTokens = TokenTable.empty;
			state.lastGoodAst = null;
			state.lastGoodSemanticModel = null;
			state.canonicalFunctions = [];
			state.canonicalAllFunctions = [];
			state.canonicalProgramFunctions = [];
			state.canonicalAliases = [];
			state.canonicalEnums = [];
			state.canonicalAbstracts = [];
			state.canonicalInterfaces = [];
			state.canonicalClasses = [];
			state.canonicalNamespaceUses = [];
			state.canonicalFunctionNamespaceUses = [];
			// Nothing canonical is left to reuse: a later canonicalization starts over.
			state.canonicalRevision = -1;
		}

	/**
	 * Releases the records only a next build reads to decide what to redo (dependency edges, fingerprints, the answers typed bodies
	 * relied on, the inferred signatures and declaration types), for a compile that keeps no session once its frontend has assembled
	 * the IR tables, with the facts the typed units' reads name. Changes the modules in place, as `releaseRetained` does.
	 */
	public function releaseIncrementalRecords():Void {
		declarationFacts.clear();
		for (state in modules) {
			state.signatureFingerprints = [];
			state.interfaceFingerprints = [];
			state.aliasFingerprints = [];
			state.enumFingerprints = [];
			state.wireFieldFingerprints = [];
			state.abstractFingerprints = [];
			state.ownerConstraintFingerprints = [];
			state.staticFieldFingerprints = [];
			state.instanceInitializerFingerprints = [];
			state.bodyFingerprints = [];
			state.declarationTypeDigests = [];
			state.inferredSignatures = [];
			state.keyPathUses = [];
		}
	}

	/** A state of its own, or, given `sharing`, one sharing its query database, as a copy of it does. */
	public function new(types:TypeRegistry, genericSpecializations:GenericSpecializationRegistry,
			backend:BackendSession, ?sharing:SessionState) {
		semanticWorkspace = new SemanticWorkspace(modules);
		if (sharing == null) {
			queries = new QueryDatabase();
			declarationFacts = new compiler.semantic.DeclarationFacts(queries);
			inputs = new BuildInputs(queries);
			var symbolName = (id:Int) -> IrSymbol.at(id).name;
			var generation = queries.register(new ComputedQueryKind<IrFunction>("ir-generation",
				IrFunctionStateEquality.same, null,
				symbolName));
			irGeneration = generation;
			irObjects = queries.register(new ComputedQueryKind<IrObject>("ir-objects", IrDeclarationEquality.sameObject,
				null,
				symbolName));
			initializerInputs = queries.register(new ComputedQueryKind<Array<TypedField>>("initializer-inputs",
				sameFields, null,
				symbolName));
			irTypeMentions =
				queries.register(new ComputedQueryKind<FrontendCompilation.TypeMentions>("ir-type-mentions",
				FrontendCompilation.sameTypeMentions,
				(database, key) -> FrontendCompilation.typeMentions(generation.get(database, key)), symbolName));
			irCalls = queries.register(new ComputedQueryKind<Array<String>>("ir-calls",
				compiler.ir.model.Ir.IrObjectTools.sameNames,
				(database, key) -> FrontendCompilation.callsIn(generation.get(database, key)), symbolName));
			staticReferences = queries.register(new ComputedQueryKind<IrStaticReferences>("static-references",
				IrStaticReferences.same, (database, key) -> IrStaticReferences.of(generation.get(database, key)),
				symbolName));
		} else {
			queries = sharing.queries;
			declarationFacts = sharing.declarationFacts;
			inputs = sharing.inputs;
			irGeneration = sharing.irGeneration;
			irObjects = sharing.irObjects;
			initializerInputs = sharing.initializerInputs;
			irTypeMentions = sharing.irTypeMentions;
			irCalls = sharing.irCalls;
			staticReferences = sharing.staticReferences;
		}
		assemblyOrder = sharing == null ? new FrontendCompilation.AssemblyOrder() : sharing.assemblyOrder;
		stageMemos = new compiler.ir.reuse.IrStageMemo.IrStageMemos(queries, irGeneration);
		this.types = types;
		this.genericSpecializations = genericSpecializations;
		this.backend = backend;
	}

	/**
	 * The state a build works on: everything a build changes is copied (a module is copied when it is first written,
	 * `writableState`), so this state stays what it was whatever the build does. The backend is `startingBackend` when given, which
	 * the build takes as its own (`BackendSession.forCandidate`).
	 */
	public function copyForCandidate(?startingBackend:BackendSession):SessionState {
		// A build starts from the records this state was taken with: what a build that was not taken wrote is undone.
		queries.rollBack(committed);
		var result = new SessionState(types.copy(), genericSpecializations.copy(),
			(startingBackend == null ? backend : startingBackend).forCandidate(), this);
		for (name => state in modules)
			result.modules.set(name, state);
		result.objects = objects.copy();
		result.lastTypedProgram = lastTypedProgram;
		result.semanticProgram = semanticProgram;
		result.programFacts = programFacts;
		result.publishedAbi = publishedAbi;
		result.compiledOnce = compiledOnce;
		result.committed = committed;
		result.rehydrationBaseline = rehydrationBaseline;
		result.inlineCache = inlineCache.copy();
		result.stageMemos = stageMemos;
		result.pipelineSnapshot = pipelineSnapshot;
		result.verifyMemo = verifyMemo;
		result.reachabilityCache = reachabilityCache.copy();
		result.declarationOwners = declarationOwners.copy();
		return result;
	}

	/** Whether two lists hold the same typed fields, in order: a typed field is never changed once made. */
	static function sameFields(left:Array<TypedField>, right:Array<TypedField>):Bool {
		if (left.length != right.length)
			return false;
		for (index in 0...left.length)
			if (left[index] != right[index])
				return false;
		return true;
	}

	/**
	 * A state with this one's sources and nothing a build left in it: what a first build of the same text starts from. The frontend's
	 * reuse check (`--check-reuse`) builds the program on it and compares.
	 */
	public function freshFromSources():SessionState {
		var result = new SessionState(new TypeRegistry(), new GenericSpecializationRegistry(), backend.forCandidate());
		for (name => state in modules)
			result.modules.set(name, new ModuleState(name, state.source));
		return result;
	}

	/** The module `name`, copied first when it is still the one `rollback` holds, so a build never writes a module it shares. */
	public function writableState(name:String, rollback:Map<String, ModuleState>):ModuleState {
		var state:ModuleState = modules.get(name);
		if (rollback.get(name) == state) {
			state = state.copy();
			modules.set(name, state);
		}
		return state;
	}

	/** The function a program of the entry module starts at; an analysis without an entry gives the name a program would. */
	public function executableEntryPoint(entryModule:String):String {
		if (entryModule == compiler.modules.ModuleReachability.NO_ENTRY)
			return "main";
		var state:ModuleState = modules.get(entryModule),
			ast = state.parsedAst();
		for (fn in ast.functions)
			if (fn.name == "main")
				return "main";
		for (classDecl in ast.classes)
			for (method in classDecl.methods)
				if (method.name == "main" && method.isStatic)
					return ModuleCanonicalizer.qualifiedTypeName(ast.packageName, classDecl.name) + ".main";
		return "main";
	}

	/**
	 * Where a missing entry point is reported: at the entry module's type named as the module, as Haxe reports `-main Main` at
	 * class Main, else at the module's first declaration, else at the start of its file.
	 */
	public function executableEntrySpan(entryModule:String):Null<SourceSpan> {
		// An analysis without an entry requires none, so has no missing entry point to report.
		if (entryModule == compiler.modules.ModuleReachability.NO_ENTRY)
			return null;
		var state:ModuleState = modules.get(entryModule),
			ast = state.parsedAst(),
			typeName = QualifiedName.last(entryModule);
		for (classDecl in ast.classes)
			if (classDecl.name == typeName)
				return classDecl.span;
		var first:Null<SourceSpan> = null;
		function consider(span:SourceSpan)
			if (first == null || span.start < first.start)
				first = span;
		for (classDecl in ast.classes)
			consider(classDecl.span);
		for (fn in ast.functions)
			consider(fn.span);
		for (enumDecl in ast.enums)
			consider(enumDecl.span);
		for (abstractDecl in ast.abstracts)
			consider(abstractDecl.span);
		for (interfaceDecl in ast.interfaces)
			consider(interfaceDecl.span);
		for (alias in ast.aliases)
			consider(alias.span);
		return first ?? new SourceSpan(state.source, 0, 0);
	}

	/** The modules reachable for `key`, the entry and the roots of a build (`FrontendCompilation`). */
	public function cachedReachability(key:String):Null<ReachabilityCache>
		return reachabilityCache.get(key);

	public function cacheReachability(key:String, names:Array<String>, initializationClasses:Array<String>):Void {
		var dependencyKeys:Map<String, String> = [];
		for (name in names) {
			var state = modules.get(name);
			if (state != null)
				dependencyKeys.set(name, CompilationContext.dependencyKey(state.dependencies));
		}
		reachabilityCache.set(key, {
			names: names.copy(),
			dependencyKeys: dependencyKeys,
			initializationClasses: initializationClasses.copy()
		});
	}
}
