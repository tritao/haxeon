package compiler.modules;

import compiler.core.Diagnostic;
import compiler.core.InternalError;
import compiler.core.Source.SourceFile;
import compiler.ir.model.IrFunction;
import compiler.semantic.SemanticModel;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstProgram;
import compiler.syntax.TokenTable;
import compiler.types.DeclarationTypes.InferredSignature;
import compiler.types.TypedAst.TypedFunction;

/**
 * Incremental artifacts and last-known-good state owned by one source module.
 * Failed edits may update diagnostics but must not replace the last good tree.
 */
class ModuleState {
	public final name:String;
	public var source:SourceFile;

	/**
	 * The text the caller supplied for this module, such as the file as read from disk. It is what an incoming copy of the
	 * file is compared with, and differs from `source.text` when the compiler generates the text it compiles.
	 */
	public var loadedText:String;
	public var revision:Int = 1;
	public var parseVersion:Int = 0;
	public var typeVersion:Int = 0;
	public var tokens = TokenTable.empty;
	public var ast:Null<AstProgram>;
	public var recoveredAst:Null<AstProgram>;
	public var recoveredTokens = TokenTable.empty;
	public var recoveredSemanticModel:Null<SemanticModel>;
	public var semanticModel:Null<SemanticModel>;
	public var lastGoodTokens = TokenTable.empty;
	public var lastGoodAst:Null<AstProgram>;
	public var lastGoodSemanticModel:Null<SemanticModel>;
	public var lastGoodSource:Null<SourceFile>;
	public var lastGoodRevision:Int = 0;
	public var dependencies:Array<String> = [];
	public var conditionalDefines:Array<String> = [];
	public var diagnostics:Array<Diagnostic> = [];
	public var signatureFingerprints:Map<String, String> = [];
	public var interfaceFingerprints:Map<String, String> = [];
	public var aliasFingerprints:Map<String, String> = [];
	public var enumFingerprints:Map<String, String> = [];
	public var wireFieldFingerprints:Map<String, String> = [];
	public var abstractFingerprints:Map<String, String> = [];
	public var ownerConstraintFingerprints:Map<String, String> = [];
	public var staticFieldFingerprints:Map<String, String> = [];
	public var instanceInitializerFingerprints:Map<String, String> = [];
	public var bodyFingerprints:Map<String, compiler.semantic.BodyFingerprint> = [];

	/**
	 * The type each unannotated declaration of the module was typed with when it was last typed, spelled by `SemanticSignature`: the
	 * recorded answer that the readers of its type (its `DeclarationType` edges) were typed against. `--check-reuse` checks that
	 * a declaration whose type changed had every such reader typed again.
	 */
	public var declarationTypeDigests:Map<String, String> = [];

	/**
	 * The signature each unannotated function of the module was given by its body when it was last typed, by its key
	 * (`DeclarationTypeTable.functionKey`): a warm build gives it to the functions it does not type again, instead of typing their
	 * bodies to read their signatures (`DeclarationTypeTable.seedFunctions`).
	 */
	public var inferredSignatures:Map<String, InferredSignature> = [];

	/**
	 * Typing warnings by the source function or field initializer that raised them (see TypingWarnings). A body typed again
	 * replaces its entry; one an incremental compile reuses keeps it.
	 */
	public var typingWarnings:Map<String, Array<Diagnostic>> = [];

	/**
	 * Warnings about the whole program raised after typing, at this module's declarations (the static initialization order's
	 * loops): every build that generates the program replaces them (`TypingWarnings.publishGeneration`).
	 */
	public var generationWarnings:Array<Diagnostic> = [];
	public var typedFunctions:Map<String, TypedFunction> = [];
	public var typedSourceRevisions:Map<String, Int> = [];

	/**
	 * What each unit of this module read when it was last typed (`DeclarationFacts`), by unit: a function, a field initializer
	 * (`Class.__init.x`) or a shared unit. A unit is typed again when a fact it read changed after it was typed.
	 */
	public var unitReads:Map<String, compiler.semantic.DeclarationFacts.UnitReads> = [];

	/** The key path literals each typed function uses; a literal's helpers stay only while one is used. */
	public var keyPathUses:Map<String, Map<String, Bool>> = [];

	/** Typed functions changed by analysis and awaiting build-time IR lowering. */
	public var pendingIrFunctions:Map<String, Bool> = [];

	public var irFunctions:Map<String, IrFunction> = [];
	public var irSourceRevisions:Map<String, Int> = [];
	/**
	 * By name, the version of the function's IR in `irFunctions`, from the session's counter (`SessionState.irVersions`): it
	 * changes exactly when the function is given another IR, regenerated or rehashed.
	 */
	public var irVersions:Map<String, Int> = [];

	public var dirty:Bool = true;
	public var canonicalFunctions:Array<AstFunction> = [];
	public var canonicalAllFunctions:Array<AstFunction> = [];

	/** The module-namespace uses of the module's canonical code (AliasTable.ModuleNamespaceUse), and of its functions alone. */
	public var canonicalNamespaceUses:Array<compiler.semantic.AliasTable.ModuleNamespaceUse> = [];

	public var canonicalFunctionNamespaceUses:Array<compiler.semantic.AliasTable.ModuleNamespaceUse> = [];
	public var canonicalProgramFunctions:Array<AstFunction> = [];
	public var canonicalAliases:Array<compiler.syntax.Ast.AstTypeAlias> = [];
	public var canonicalEnums:Array<compiler.syntax.Ast.AstEnum> = [];
	public var canonicalAbstracts:Array<compiler.syntax.Ast.AstAbstract> = [];
	public var canonicalInterfaces:Array<compiler.syntax.Ast.AstInterface> = [];
	public var canonicalClasses:Array<compiler.syntax.Ast.AstClass> = [];
	public var canonicalGeneratedFunctions:Array<String> = [];
	public var canonicalRevision:Int = 0;
	public var canonicalEntry:String = "";
	public var canonicalAliasKey:String = "";

	/**
	 * What the module's canonical declarations were resolved in, besides their own text (`SemanticAssembly.scopeKey`): the names
	 * every module sees and the module's imports and declarations.
	 */
	public var canonicalScope:String = "";

	/**
	 * The key of the static extensions the module's bodies were typed with (`StaticExtensionTable.keyOfModule`): when it changes,
	 * they are typed again, since a call may resolve to another extension.
	 */
	public var staticExtensionKey:String = "";

	public function new(name, source) {
		this.name = name;
		this.source = source;
		this.loadedText = source.text;
	}

	public function parsedAst():AstProgram {
		var result = ast;
		if (result == null)
			throw new InternalError('Module "$name" has not been parsed');
		return result;
	}

	/** The caller supplied new text for the module. */
	/**
	 * The text of the file changed after IR may have been made from the old one: functions kept across the edit, and helpers whose spans
	 * come from this file, can still name its old content hash. The frontend gives them the current hashes once and clears this.
	 */
	public var editedSinceIrScan = false;

	public function update(source:SourceFile):Void {
		loadedText = source.text;
		render(source);
	}

	/** The compiler replaces the text it compiles; the text the caller supplied stays as it was. */
	public function render(source:SourceFile):Void {
		this.source = source;
		if (revision > 0)
			editedSinceIrScan = true;
		revision++;
		tokens = TokenTable.empty;
		ast = null;
		recoveredAst = null;
		recoveredTokens = TokenTable.empty;
		recoveredSemanticModel = null;
		semanticModel = null;
		diagnostics = [];
		dirty = true;
	}

	public function copy():ModuleState {
		var result = new ModuleState(name, source);
		result.loadedText = loadedText;
		result.revision = revision;
		result.editedSinceIrScan = editedSinceIrScan;
		result.parseVersion = parseVersion;
		result.typeVersion = typeVersion;
		result.tokens = tokens;
		result.ast = ast;
		result.recoveredAst = recoveredAst;
		result.recoveredTokens = recoveredTokens;
		result.recoveredSemanticModel = recoveredSemanticModel;
		result.semanticModel = semanticModel;
		result.lastGoodTokens = lastGoodTokens;
		result.lastGoodAst = lastGoodAst;
		result.lastGoodSemanticModel = lastGoodSemanticModel;
		result.lastGoodSource = lastGoodSource;
		result.lastGoodRevision = lastGoodRevision;
		result.dependencies = dependencies.copy();
		result.conditionalDefines = conditionalDefines.copy();
		result.diagnostics = diagnostics.copy();
		result.typingWarnings = [for (key => warnings in typingWarnings) key => warnings.copy()];
		result.generationWarnings = generationWarnings.copy();
		result.signatureFingerprints = copyMap(signatureFingerprints);
		result.interfaceFingerprints = copyMap(interfaceFingerprints);
		result.aliasFingerprints = copyMap(aliasFingerprints);
		result.enumFingerprints = copyMap(enumFingerprints);
		result.wireFieldFingerprints = copyMap(wireFieldFingerprints);
		result.abstractFingerprints = copyMap(abstractFingerprints);
		result.ownerConstraintFingerprints = copyMap(ownerConstraintFingerprints);
		result.staticFieldFingerprints = copyMap(staticFieldFingerprints);
		result.instanceInitializerFingerprints = copyMap(instanceInitializerFingerprints);
		result.bodyFingerprints = copyMap(bodyFingerprints);
		result.declarationTypeDigests = copyMap(declarationTypeDigests);
		result.inferredSignatures = copyMap(inferredSignatures);
		result.typedFunctions = copyMap(typedFunctions);
		result.typedSourceRevisions = copyMap(typedSourceRevisions);
		result.unitReads = copyMap(unitReads);
		result.keyPathUses = copyNestedMap(keyPathUses);
		result.pendingIrFunctions = copyMap(pendingIrFunctions);
		result.irFunctions = copyMap(irFunctions);
		result.irSourceRevisions = copyMap(irSourceRevisions);
		result.irVersions = copyMap(irVersions);
		result.dirty = dirty;
		result.canonicalFunctions = canonicalFunctions;
		result.canonicalAllFunctions = canonicalAllFunctions;
		result.canonicalNamespaceUses = canonicalNamespaceUses;
		result.canonicalFunctionNamespaceUses = canonicalFunctionNamespaceUses;
		result.canonicalProgramFunctions = canonicalProgramFunctions;
		result.canonicalAliases = canonicalAliases;
		result.canonicalEnums = canonicalEnums;
		result.canonicalAbstracts = canonicalAbstracts;
		result.canonicalInterfaces = canonicalInterfaces;
		result.canonicalClasses = canonicalClasses;
		result.canonicalGeneratedFunctions = canonicalGeneratedFunctions;
		result.canonicalRevision = canonicalRevision;
		result.canonicalEntry = canonicalEntry;
		result.canonicalAliasKey = canonicalAliasKey;
		result.canonicalScope = canonicalScope;
		result.staticExtensionKey = staticExtensionKey;
		return result;
	}

	static function copyMap<T>(source:Map<String, T>):Map<String, T> {
		var result:Map<String, T> = [];
		for (name => value in source)
			result.set(name, value);
		return result;
	}

	static function copyNestedMap<T>(source:Map<String, Map<String, T>>):Map<String, Map<String, T>> {
		var result:Map<String, Map<String, T>> = [];
		for (name => record in source)
			result.set(name, copyMap(record));
		return result;
	}
}
