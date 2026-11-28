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
import compiler.types.typing.DeclarationKeys.ModuleDeclarationKeys;
import compiler.types.typing.RetainedFromPrevious.OwnerSpecialization;
import haxe.io.Bytes;

/** The modules an entry reached in its last build, with what each depended on then. */
typedef ReachabilityCache = {
	final names:Array<String>;
	final dependencies:Map<String, Array<String>>;
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

	/**
	 * The purity and never-returns answers over the last canonical program (`SemanticAssembly`). Every copy shares them: they are
	 * brought up to date from whatever program they were last over, and the facts they move only move forward.
	 */
	public var purity(default, null):compiler.semantic.ProgramPurity;

	/**
	 * When the units of `unitsCheckedIn`'s modules were last checked against what they read, as a count of the facts' changes
	 * (`DeclarationFacts.changeCount`): each was current then or typed after, so only a fact changed since can have changed one
	 * (`DeclarationFacts.unitsReading`). `unitsCheckedIn` is null before any check.
	 */
	public var unitsCheckedAt:Int = 0;

	public var unitsCheckedIn:Null<Map<String, Bool>> = null;

	/** The units that check found changed: one a build does not type again (an initializer whose field is gone) stays changed. */
	public var unitsPending:Array<Int> = [];

	/**
	 * The names every module's canonicalization resolves against, as `SemanticAssembly` keys them (`ProgramNames.universe`), and the
	 * build revision they took this value at: a module records the revision, so a build compares one number per module instead of
	 * the whole key.
	 */
	public var aliasUniverse:Null<String> = null;

	public var aliasUniverseRevision:Int = 0;

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
	 * assembler make (`IrStageMemos.startBuild`). An IR made again the same keeps last build's object and the revision it changed at, so
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
	 * What the IR stages made of each function (`IrStageMemos`), mostly in the session's database; every copy shares it, as a memo
	 * holds only for the function object it was made from and the facts it read.
	 */
	public var stageMemos(default, null):compiler.ir.reuse.IrStageMemos;

	/**
	 * What the HashLink backend's steps over the final IR work out from each function (`HlFunctionQueries`), in the session's
	 * database; every copy shares it, as `stageMemos`.
	 */
	public var hlFunctions(default, null):compiler.hl.incremental.HlFunctionQueries;

	/**
	 * What each function of `irGeneration` references for the static initialization order, by the same key: it holds while the
	 * function does. Every copy shares it, as `irGeneration`.
	 */
	public var staticReferences(default, null):ComputedQueryKind<IrStaticReferences>;

	/**
	 * The declaration keys of each module's canonical declarations (`ModuleDeclarationKeys`), by module id (`BuildInputs.moduleId`):
	 * put every build, the kept one while the module keeps its canonical declarations, so a build makes keys only for the modules
	 * canonicalized again. Every copy shares it.
	 */
	public var declarationKeys(default, null):ComputedQueryKind<ModuleDeclarationKeys>;

	/**
	 * What each module's parse gives the names every module sees (`ModuleNames`), by module id, and those names (`ProgramNames`), at
	 * key 0: put every build by `SemanticAssembly`, the kept ones while the modules give the same names. Every copy shares them.
	 */
	public var moduleNames(default, null):ComputedQueryKind<compiler.semantic.ProgramNames.ModuleNames>;

	public var programNames(default, null):ComputedQueryKind<compiler.semantic.ProgramNames>;

	/**
	 * The generic owner specializations the last builds typed, with what typing each produced (`OwnerSpecialization`), by the
	 * specialization's symbol: put every build by the typer, the kept one while nothing it read changed (`RetainedFromPrevious`).
	 * Every copy shares it.
	 */
	public var ownerSpecializations(default, null):ComputedQueryKind<OwnerSpecialization>;

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

	public var reachabilityCache(default, null):Map<String, ReachabilityCache> = [];

	/**
	 * The names of the modules that entered or left the program (`Compiler.update`, `Compiler.remove`) since a build last resolved
	 * again the modules whose dependencies read them (`ModuleState.resolutionReads`, `FrontendCompilation.resolveAgainAfterModuleSetChanges`).
	 */
	public var moduleSetChanges:Array<String> = [];
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
		for (state in modules) {
			state.typedFunctions = [];
			state.functionEdges = null;
		}
		objects = [];
		lastTypedProgram = null;
		semanticProgram = null;
		purity.clear();
		inlineCache = new IrInlineCache();
		stageMemos.clear();
		pipelineSnapshot = null;
		reachabilityCache = [];
	}

	/**
	 * Releases the modules' generated IR functions, for a compile that keeps no session once its IR pipeline has its input: the
	 * passes then hold the only copy of the program. The memos keyed by those functions are emptied with them, as their keys would
	 * keep the functions alive, and so are the printers and boot functions kept with their inputs. Changes the modules and the
	 * memos in place, as `releaseRetained` does.
	 */
	public function releaseGeneratedIr():Void {
		for (state in modules) {
			state.irFunctions = [];
			state.functionEdges = null;
		}
		irGeneration.clear();
		irObjects.clear();
		initializerInputs.clear();
		staticReferences.clear();
	}

	/**
	 * Releases the modules' tokens, syntax trees, semantic models and canonical declarations, for a compile that keeps no session
	 * once typing is done: the IR is assembled from the typed program. What the session keeps of them for a next build goes too:
	 * the names every module sees hold the parses, and the declaration keys the canonical declarations. Changes the modules and
	 * those kinds in place, as `releaseRetained` does.
	 */
	public function releaseSyntax():Void {
		declarationKeys.clear();
		moduleNames.clear();
		programNames.clear();
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
	}

	/**
	 * Releases the records only a next build reads to decide what to redo (dependency edges, fingerprints, the answers typed bodies
	 * relied on, the inferred signatures and declaration types), for a compile that keeps no session once its frontend has assembled
	 * the IR tables, with the facts the typed units' reads name. Changes the modules in place, as `releaseRetained` does.
	 */
	public function releaseIncrementalRecords():Void {
		declarationFacts.clear();
		purity.clear();
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
			state.resolutionReads = [];
		}
	}

	/** A state of its own, or, given `sharing`, one sharing its query database, as a copy of it does. */
	public function new(types:TypeRegistry, genericSpecializations:GenericSpecializationRegistry,
			backend:BackendSession, ?sharing:SessionState) {
		semanticWorkspace = new SemanticWorkspace(modules);
		if (sharing == null) {
			queries = new QueryDatabase();
			declarationFacts = new compiler.semantic.DeclarationFacts(queries);
			purity = new compiler.semantic.ProgramPurity(declarationFacts);
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
			staticReferences = queries.register(new ComputedQueryKind<IrStaticReferences>("static-references",
				IrStaticReferences.same, (database, key) -> IrStaticReferences.of(generation.get(database, key)),
				symbolName));
			var moduleInputs = inputs;
			declarationKeys = queries.register(new ComputedQueryKind<ModuleDeclarationKeys>("declaration-keys",
				(left, right) -> left == right, null, moduleInputs.moduleName, true));
			moduleNames =
				queries.register(new ComputedQueryKind<compiler.semantic.ProgramNames.ModuleNames>("module-names",
				(left, right) -> left == right, null, moduleInputs.moduleName, true));
			programNames = queries.register(new ComputedQueryKind<compiler.semantic.ProgramNames>("program-names",
				(left, right) -> left == right, null, null, true));
			ownerSpecializations = queries.register(new ComputedQueryKind<OwnerSpecialization>("owner-specializations",
				(left, right) -> left == right, null, symbolName, true));
		} else {
			queries = sharing.queries;
			declarationFacts = sharing.declarationFacts;
			purity = sharing.purity;
			inputs = sharing.inputs;
			irGeneration = sharing.irGeneration;
			irObjects = sharing.irObjects;
			initializerInputs = sharing.initializerInputs;
			staticReferences = sharing.staticReferences;
			declarationKeys = sharing.declarationKeys;
			moduleNames = sharing.moduleNames;
			programNames = sharing.programNames;
			ownerSpecializations = sharing.ownerSpecializations;
		}
		assemblyOrder = sharing == null ? new FrontendCompilation.AssemblyOrder() : sharing.assemblyOrder;
		stageMemos = sharing == null ? new compiler.ir.reuse.IrStageMemos(queries,
			irGeneration) : sharing.stageMemos;
		hlFunctions = sharing == null ? new compiler.hl.incremental.HlFunctionQueries(queries,
			stageMemos.stageFacts) : sharing.hlFunctions;
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
		result.unitsCheckedAt = unitsCheckedAt;
		result.unitsCheckedIn = unitsCheckedIn;
		result.unitsPending = unitsPending;
		result.aliasUniverse = aliasUniverse;
		result.aliasUniverseRevision = aliasUniverseRevision;
		result.publishedAbi = publishedAbi;
		result.compiledOnce = compiledOnce;
		result.committed = committed;
		result.rehydrationBaseline = rehydrationBaseline;
		result.inlineCache = inlineCache.copy();
		result.pipelineSnapshot = pipelineSnapshot;
		result.reachabilityCache = reachabilityCache.copy();
		result.moduleSetChanges = moduleSetChanges.copy();
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
		for (name => state in modules) {
			var fresh = new ModuleState(name, state.source);
			fresh.packageCode = state.packageCode;
			result.modules.set(name, fresh);
		}
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

	/** Whether a module depends on what `cached` recorded of it: compared name by name, so a build that reuses the graph makes nothing. */
	public static function sameDependencies(cached:Null<Array<String>>, dependencies:Array<String>):Bool {
		if (cached == dependencies)
			return true;
		if (cached == null || cached.length != dependencies.length)
			return false;
		for (index in 0...dependencies.length)
			if (cached[index] != dependencies[index])
				return false;
		return true;
	}

	public function cacheReachability(key:String, names:Array<String>, initializationClasses:Array<String>):Void {
		var dependencies:Map<String, Array<String>> = [];
		for (name in names) {
			var state = modules.get(name);
			// A module's dependencies are replaced whole when it is analyzed again, never changed in place.
			if (state != null)
				dependencies.set(name, state.dependencies);
		}
		reachabilityCache.set(key, {
			names: names.copy(),
			dependencies: dependencies,
			initializationClasses: initializationClasses.copy()
		});
	}
}
