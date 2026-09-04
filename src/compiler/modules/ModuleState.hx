package compiler.modules;

import compiler.Ast.AstProgram;
import compiler.Diagnostic;
import compiler.Source.SourceFile;
import compiler.ir.Ir.IrProgram;
import compiler.types.TypedAst.TypedFunction;

class ModuleState {
    public final name:String;
    public var source:SourceFile;
    public var revision:Int = 1;
    public var parseVersion:Int = 0;
    public var typeVersion:Int = 0;
    public var tokens:Array<Token>;
    public var ast:Null<AstProgram>;
    public var typed:Array<TypedFunction>;
    public var dependencies:Array<String> = [];
    public var diagnostics:Array<Diagnostic> = [];
    public var ir:Null<IrProgram>;

    public function new(name, source) { this.name = name; this.source = source; }
    public function update(source:SourceFile):Void { this.source=source; revision++; tokens=null; ast=null; typed=null; ir=null; diagnostics=[]; }
    public function invalidateTyped():Void { typed=null; ir=null; }
}
