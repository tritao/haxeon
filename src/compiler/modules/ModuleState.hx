package compiler.modules;

import compiler.Ast.AstProgram;
import compiler.Diagnostic;
import compiler.Source.SourceFile;
import compiler.ir.IrFunction;
import compiler.types.TypedAst.TypedFunction;

enum abstract SemanticDependencyKind(String) {
	var Signature = "signature";
	var Body = "body";
	var Layout = "layout";
	var Initializer = "initializer";
}

typedef SemanticDependency = {final kind:SemanticDependencyKind; final target:String;}

class ModuleState {
	public final name:String;
	public var source:SourceFile;
	public var revision:Int = 1;
	public var parseVersion:Int = 0;
	public var typeVersion:Int = 0;
	public var tokens:Array<Token>;
	public var ast:Null<AstProgram>;
	public var lastGoodTokens:Array<Token>;
	public var lastGoodAst:Null<AstProgram>;
	public var lastGoodSource:Null<SourceFile>;
	public var lastGoodRevision:Int = 0;
	public var dependencies:Array<String> = [];
	public var semanticDependencies:Map<String, Array<SemanticDependency>> = [];
	public var diagnostics:Array<Diagnostic> = [];
	public var signatureFingerprints:Map<String, String> = [];
	public var interfaceFingerprints:Map<String, String> = [];
	public var aliasFingerprints:Map<String, String> = [];
	public var enumFingerprints:Map<String, String> = [];
	public var staticInitializerFingerprints:Map<String, String> = [];
	public var instanceInitializerFingerprints:Map<String, String> = [];
	public var bodyFingerprints:Map<String, String> = [];
	public var typedFunctions:Map<String, TypedFunction> = [];
	public var typedSourceRevisions:Map<String, Int> = [];
	public var irFunctions:Map<String, IrFunction> = [];
	public var irSourceRevisions:Map<String, Int> = [];
	public var irVersions:Map<String, Int> = [];
	public var dirty:Bool = true;

	public function new(name, source) {
		this.name = name;
		this.source = source;
	}

	public function update(source:SourceFile):Void {
		this.source = source;
		revision++;
		tokens = null;
		ast = null;
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
		result.lastGoodTokens = lastGoodTokens;
		result.lastGoodAst = lastGoodAst;
		result.lastGoodSource = lastGoodSource;
		result.lastGoodRevision = lastGoodRevision;
		result.dependencies = dependencies.copy();
		result.semanticDependencies = copyDependencyMap(semanticDependencies);
		result.diagnostics = diagnostics.copy();
		result.signatureFingerprints = copyMap(signatureFingerprints);
		result.interfaceFingerprints = copyMap(interfaceFingerprints);
		result.aliasFingerprints = copyMap(aliasFingerprints);
		result.enumFingerprints = copyMap(enumFingerprints);
		result.staticInitializerFingerprints = copyMap(staticInitializerFingerprints);
		result.instanceInitializerFingerprints = copyMap(instanceInitializerFingerprints);
		result.bodyFingerprints = copyMap(bodyFingerprints);
		result.typedFunctions = copyMap(typedFunctions);
		result.typedSourceRevisions = copyMap(typedSourceRevisions);
		result.irFunctions = copyMap(irFunctions);
		result.irSourceRevisions = copyMap(irSourceRevisions);
		result.irVersions = copyMap(irVersions);
		result.dirty = dirty;
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
