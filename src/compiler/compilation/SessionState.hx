package compiler.compilation;

import compiler.abi.RuntimeAbi.RuntimeAbiDescriptor;
import compiler.core.QualifiedName;
import compiler.core.Source.SourceSpan;
import compiler.ir.Ir.IrObject;
import compiler.ir.Ir.IrProgram;
import compiler.ir.IrInliner.IrInlineCache;
import compiler.ir.IrVerifyMemo;
import compiler.modules.ModuleState;
import compiler.semantic.DeclarationOwners;
import compiler.semantic.GenericSpecializationRegistry;
import compiler.semantic.ModuleCanonicalizer;
import compiler.semantic.SemanticProgram;
import compiler.semantic.SemanticWorkspace;
import compiler.syntax.TokenTable;
import compiler.types.TypeRegistry;
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
	public var objectCache(default, null):Map<String, IrObject> = [];
	public var canonicalObjectCache(default, null):Map<String, IrObject> = [];

	/**
	 * The `__string` of each anonymous structure type a build has made (IrProgramAssembler.anonymousStringsFrom), by function name:
	 * a warm build takes objects typed by earlier builds from `objectCache`, and each needs its printer too.
	 */
	public var anonymousStrings(default, null):Map<String, compiler.ir.IrFunction> = [];

	/** Last successfully assembled typed program; failed edits never replace it. */
	public var lastTypedProgram:Null<TypedProgram> = null;

	public var semanticProgram:Null<SemanticProgram> = null;
	public var publishedAbi:Null<RuntimeAbiDescriptor> = null;
	public var compiledOnce = false;

	/** The functions of a resumed live module, as it was published, until the first build replaces them. */
	public var rehydrationBaseline:Null<Map<String, Bytes>> = null;

	public var inlineCache(default, null):IrInlineCache = new IrInlineCache();

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
		objectCache = [];
		canonicalObjectCache = [];
		anonymousStrings = [];
		lastTypedProgram = null;
		semanticProgram = null;
		inlineCache = new IrInlineCache();
		pipelineSnapshot = null;
		verifyMemo = new IrVerifyMemo();
		reachabilityCache = [];
	}

	/**
	 * Releases the modules' generated IR functions, for a compile that keeps no session once its IR pipeline has its input: the
	 * passes then hold the only copy of the program. Changes the modules in place, as `releaseRetained` does.
	 */
	public function releaseGeneratedIr():Void
		for (state in modules)
			state.irFunctions = [];

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
			state.canonicalCalls = [];
			// Nothing canonical is left to reuse: a later canonicalization starts over.
			state.canonicalRevision = -1;
		}

	/**
	 * Releases the records only a next build reads to decide what to redo (dependency edges, fingerprints, the answers typed bodies
	 * relied on, the inferred signatures and declaration types), for a compile that keeps no session once its last frontend pass has
	 * assembled the IR tables. A pass that restarts reads them, so they are made as before and dropped only here. Changes the modules
	 * in place, as `releaseRetained` does.
	 */
	public function releaseIncrementalRecords():Void
		for (state in modules) {
			state.semanticDependencies = [];
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
			state.purityQueries = [];
			state.noReturnQueries = [];
			state.keyPathUses = [];
			state.defaultArgumentSources = [];
		}

	public function new(types:TypeRegistry, genericSpecializations:GenericSpecializationRegistry,
			backend:BackendSession) {
		semanticWorkspace = new SemanticWorkspace(modules);
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
		var result = new SessionState(types.copy(), genericSpecializations.copy(),
			(startingBackend == null ? backend : startingBackend).forCandidate());
		for (name => state in modules)
			result.modules.set(name, state);
		result.objectCache = [for (name => object in objectCache) name => object];
		result.canonicalObjectCache = [for (name => object in canonicalObjectCache) name => object];
		result.anonymousStrings = [for (name => fn in anonymousStrings) name => fn];
		result.lastTypedProgram = lastTypedProgram;
		result.semanticProgram = semanticProgram;
		result.publishedAbi = publishedAbi;
		result.compiledOnce = compiledOnce;
		result.rehydrationBaseline = rehydrationBaseline;
		result.inlineCache = inlineCache.copy();
		result.pipelineSnapshot = pipelineSnapshot;
		result.verifyMemo = verifyMemo;
		result.reachabilityCache = copyReachabilityCache(reachabilityCache);
		result.declarationOwners = declarationOwners.copy();
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

	/** The function a program of the entry module starts at. */
	public function executableEntryPoint(entryModule:String):String {
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
	public function executableEntrySpan(entryModule:String):SourceSpan {
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

	/** Of the regenerated functions, those that differ from the resumed module's (all of them when nothing was resumed). */
	public function rehydratedChanges(regenerated:Array<String>, program:IrProgram):Array<String> {
		var baseline = rehydrationBaseline;
		if (baseline == null)
			return regenerated;
		var current:Map<String, compiler.ir.IrFunction> = [], changed = [];
		for (fn in program.functions)
			current.set(fn.name, fn);
		for (name in regenerated) {
			if (!baseline.exists(name) || !current.exists(name)) {
				changed.push(name);
				continue;
			}
			var old = baseline.get(name), next = current.get(name);
			if (old.compare(compiler.ir.codec.IrFunctionStateCodec.encode(next)) != 0)
				changed.push(name);
		}
		return changed;
	}

	public function cachedReachability(entry:String):Null<ReachabilityCache>
		return reachabilityCache.get(entry);

	public function cacheReachability(entry:String, names:Array<String>, initializationClasses:Array<String>):Void {
		var dependencyKeys:Map<String, String> = [];
		for (name in names) {
			var state = modules.get(name);
			if (state != null)
				dependencyKeys.set(name, CompilationContext.dependencyKey(state.dependencies));
		}
		reachabilityCache.set(entry, {
			names: names.copy(),
			dependencyKeys: dependencyKeys,
			initializationClasses: initializationClasses.copy()
		});
	}

	static function copyReachabilityCache(source:Map<String, ReachabilityCache>):Map<String, ReachabilityCache> {
		var result:Map<String, ReachabilityCache> = [];
		for (entry => cached in source)
			result.set(entry, {
				names: cached.names.copy(),
				dependencyKeys: [for (name => key in cached.dependencyKeys) name => key],
				initializationClasses: cached.initializationClasses.copy()
			});
		return result;
	}
}
