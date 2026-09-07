package compiler.modules;

import compiler.syntax.Ast.AstProgram;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Token;
import compiler.Diagnostic;
import compiler.Source.SourceFile;
import compiler.ir.IrFunction;
import compiler.semantic.SemanticModel;
import compiler.types.TypedAst.TypedFunction;

/** Artifact boundary at which a dependent declaration observes a change. */
enum abstract SemanticDependencyKind(String) {
	var Signature = "signature";
	var Body = "body";
	var Layout = "layout";
	var Initializer = "initializer";
}

/** Dependency edge from one declaration artifact to another declaration. */
typedef SemanticDependency = {
	final kind:SemanticDependencyKind;
	final target:String;

	/** Revision-independent semantic identity when the edge was emitted by resolution. */
	final ?targetId:String;
}

/**
 * Incremental artifacts and last-known-good state owned by one source module.
 * Failed edits may update diagnostics but must not replace the last good tree.
 */
class ModuleState {
	public final name:String;
	public var source:SourceFile;
	public var revision:Int = 1;
	public var parseVersion:Int = 0;
	public var typeVersion:Int = 0;
	public var tokens:Array<Token> = [];
	public var ast:Null<AstProgram>;
	public var recoveredAst:Null<AstProgram>;
	public var recoveredTokens:Array<Token> = [];
	public var recoveredSemanticModel:Null<SemanticModel>;
	public var semanticModel:Null<SemanticModel>;
	public var lastGoodTokens:Array<Token> = [];
	public var lastGoodAst:Null<AstProgram>;
	public var lastGoodSemanticModel:Null<SemanticModel>;
	public var lastGoodSource:Null<SourceFile>;
	public var lastGoodRevision:Int = 0;
	public var dependencies:Array<String> = [];
	public var conditionalDefines:Array<String> = [];
	public var semanticDependencies:Map<String, Array<SemanticDependency>> = [];
	public var diagnostics:Array<Diagnostic> = [];
	public var signatureFingerprints:Map<String, String> = [];
	public var interfaceFingerprints:Map<String, String> = [];
	public var aliasFingerprints:Map<String, String> = [];
	public var enumFingerprints:Map<String, String> = [];
	public var abstractFingerprints:Map<String, String> = [];
	public var ownerConstraintFingerprints:Map<String, String> = [];
	public var staticInitializerFingerprints:Map<String, String> = [];
	public var instanceInitializerFingerprints:Map<String, String> = [];
	public var bodyFingerprints:Map<String, String> = [];
	public var typedFunctions:Map<String, TypedFunction> = [];
	public var typedSourceRevisions:Map<String, Int> = [];

	/** Typed functions changed by analysis and awaiting build-time IR lowering. */
	public var pendingIrFunctions:Map<String, Bool> = [];

	public var irFunctions:Map<String, IrFunction> = [];
	public var irSourceRevisions:Map<String, Int> = [];
	public var irVersions:Map<String, Int> = [];
	public var dirty:Bool = true;
	public var canonicalFunctions:Array<AstFunction> = [];
	public var canonicalRevision:Int = 0;
	public var canonicalEntry:String = "";
	public var canonicalAliasKey:String = "";
	public var canonicalCalls:Map<String, Array<String>> = [];

	public function new(name, source) {
		this.name = name;
		this.source = source;
	}

	public function parsedAst():AstProgram {
		var result = ast;
		if (result == null)
			throw 'Module "$name" has not been parsed';
		return result;
	}

	public function update(source:SourceFile):Void {
		this.source = source;
		revision++;
		tokens = [];
		ast = null;
		recoveredAst = null;
		recoveredTokens = [];
		recoveredSemanticModel = null;
		semanticModel = null;
		diagnostics = [];
		dirty = true;
	}

	public function copy():ModuleState {
		var result = new ModuleState(name, source);
		result.revision = revision;
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
		result.semanticDependencies = copyDependencyMap(semanticDependencies);
		result.diagnostics = diagnostics.copy();
		result.signatureFingerprints = copyMap(signatureFingerprints);
		result.interfaceFingerprints = copyMap(interfaceFingerprints);
		result.aliasFingerprints = copyMap(aliasFingerprints);
		result.enumFingerprints = copyMap(enumFingerprints);
		result.abstractFingerprints = copyMap(abstractFingerprints);
		result.ownerConstraintFingerprints = copyMap(ownerConstraintFingerprints);
		result.staticInitializerFingerprints = copyMap(staticInitializerFingerprints);
		result.instanceInitializerFingerprints = copyMap(instanceInitializerFingerprints);
		result.bodyFingerprints = copyMap(bodyFingerprints);
		result.typedFunctions = copyMap(typedFunctions);
		result.typedSourceRevisions = copyMap(typedSourceRevisions);
		result.pendingIrFunctions = copyMap(pendingIrFunctions);
		result.irFunctions = copyMap(irFunctions);
		result.irSourceRevisions = copyMap(irSourceRevisions);
		result.irVersions = copyMap(irVersions);
		result.dirty = dirty;
		result.canonicalFunctions = canonicalFunctions;
		result.canonicalRevision = canonicalRevision;
		result.canonicalEntry = canonicalEntry;
		result.canonicalAliasKey = canonicalAliasKey;
		result.canonicalCalls = canonicalCalls;
		return result;
	}

	static function copyMap<T>(source:Map<String, T>):Map<String, T> {
		var result:Map<String, T> = [];
		for (name => value in source)
			result.set(name, value);
		return result;
	}

	static function copyDependencyMap(source:Map<String, Array<SemanticDependency>>):Map<String, Array<SemanticDependency>> {
		var result:Map<String, Array<SemanticDependency>> = [];
		for (name => dependencies in source)
			result.set(name, dependencies.copy());
		return result;
	}
}
