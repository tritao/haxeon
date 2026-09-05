package compiler.modules;

import compiler.Ast.AstProgram;
import compiler.Diagnostic;
import compiler.Source.SourceFile;
import compiler.ir.IrFunction;
import compiler.types.TypedAst.TypedFunction;

class ModuleState {
	public final name:String;
	public var source:SourceFile;
	public var revision:Int = 1;
	public var parseVersion:Int = 0;
	public var typeVersion:Int = 0;
	public var tokens:Array<Token>;
	public var ast:Null<AstProgram>;
	public var dependencies:Array<String> = [];
	public var diagnostics:Array<Diagnostic> = [];
	public var signatureFingerprints:Map<String, String> = [];
	public var interfaceFingerprints:Map<String, String> = [];
	public var bodyFingerprints:Map<String, String> = [];
	public var typedFunctions:Map<String, TypedFunction> = [];
	public var irFunctions:Map<String, IrFunction> = [];
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
}
