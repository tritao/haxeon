package compiler.modules;

import compiler.Ast;
import compiler.Ast.AstExpression;
import compiler.Ast.AstFunction;
import compiler.Ast.AstStatement;
import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.Lexer;
import compiler.Parser;
import compiler.Source.SourceFile;
import compiler.ir.Ir.IrProgram;
import compiler.ir.IrGenerator;
import compiler.types.Typer;
import compiler.types.TypedAst.TypedProgram;

typedef CompileResult = { final ir:IrProgram; final retyped:Array<String>; }

class Compiler {
    public final modules:Map<String, ModuleState> = [];
    final graph = new ModuleGraph();

    public function new() {}

    public function update(path:String, source:String):ModuleState {
        var name = ModulePath.fromFile(path), file = new SourceFile(path, source);
        var state = modules.get(name);
        if (state == null) { state = new ModuleState(name, file); modules.set(name, state); }
        else {
            var invalid = graph.dependents(name);
            state.update(file);
            for (dependent in invalid) modules.get(dependent).invalidateTyped();
        }
        return state;
    }

    public function compile(entryModule:String):CompileResult {
        if (!modules.exists(entryModule)) throw 'Missing entry module "$entryModule"';
        var names = [for (name in modules.keys()) name]; names.sort(Reflect.compare);
        for (name in names) parse(modules.get(name));
        graph.rebuild(modules);
        for (name in names) for (dependency in modules.get(name).dependencies)
            if (!modules.exists(dependency)) {
                var state=modules.get(name), span=state.source.span(0, state.source.text.length);
                var diagnostic=new Diagnostic("E2001", 'Missing module "$dependency"', span);
                state.diagnostics.push(diagnostic);
                throw new CompileError(diagnostic);
            }

        var functions:Array<AstFunction> = [], selected:Map<String,Bool> = [];
        for (name in names) {
            var state=modules.get(name), locals:Map<String,Bool>=[];
            for(fn in state.ast.functions) locals.set(fn.name,true);
            for(fn in state.ast.functions) {
                var canonical=canonicalFunction(fn,name,entryModule,locals);
                functions.push(canonical);
                if(state.typed==null) selected.set(canonical.name,true);
            }
        }
        var typedNew:TypedProgram;
        try typedNew = Typer.typeSelected({functions:functions}, selected) catch(error:CompileError) {
            for(name in names) {
                var state=modules.get(name);
                if(state.source.path==error.diagnostic.span.file.path) state.diagnostics.push(error.diagnostic);
            }
            throw error;
        }
        var retyped=[];
        for (name in names) {
            var state=modules.get(name);
            if (state.typed == null) {
                state.typeVersion++; retyped.push(name);
                state.typed = [for(fn in typedNew.functions) if (owner(fn.name,entryModule)==name) fn];
            }
        }
        var typed:TypedProgram={functions:[]};
        for(name in names) for(fn in modules.get(name).typed) typed.functions.push(fn);
        var ir=IrGenerator.generate(typed);
        for(name in retyped) modules.get(name).ir=ir;
        return {ir:ir,retyped:retyped};
    }

    function parse(state:ModuleState):Void {
        if (state.ast != null) return;
        try {
            state.tokens=new Lexer(state.source).tokenize();
            state.ast=new Parser(state.tokens).parseProgram(); state.parseVersion++;
        } catch(error:CompileError) {
            state.diagnostics.push(error.diagnostic); throw error;
        }
        var dependencies:Map<String,Bool>=[];
        for(fn in state.ast.functions) for(statement in fn.statements) scanStatement(statement,dependencies);
        state.dependencies=[for(name in dependencies.keys()) name]; state.dependencies.sort(Reflect.compare);
    }

    static function canonicalFunction(fn:AstFunction,module:String,entry:String,locals:Map<String,Bool>):AstFunction {
        var name = module==entry && fn.name=="main" ? "main" : module+"."+fn.name;
        return {name:name,arguments:fn.arguments,result:fn.result,span:fn.span,
            statements:[for(s in fn.statements) canonicalStatement(s,module,entry,locals)]};
    }
    static function canonicalStatement(s,module,entry,locals):AstStatement return switch s {
        case VarDeclaration(n,t,e,span): VarDeclaration(n,t,canonicalExpression(e,module,entry,locals),span);
        case Return(e,span): Return(canonicalExpression(e,module,entry,locals),span);
        case If(c,y,n,span): If(canonicalExpression(c,module,entry,locals),[for(x in y) canonicalStatement(x,module,entry,locals)],[for(x in n) canonicalStatement(x,module,entry,locals)],span);
    }
    static function canonicalExpression(e,module,entry,locals):AstExpression return switch e {
        case IntegerLiteral(_,_), Variable(_,_): e;
        case Add(a,b,s): Add(canonicalExpression(a,module,entry,locals),canonicalExpression(b,module,entry,locals),s);
        case Sub(a,b,s): Sub(canonicalExpression(a,module,entry,locals),canonicalExpression(b,module,entry,locals),s);
        case Less(a,b,s): Less(canonicalExpression(a,module,entry,locals),canonicalExpression(b,module,entry,locals),s);
        case LessEqual(a,b,s): LessEqual(canonicalExpression(a,module,entry,locals),canonicalExpression(b,module,entry,locals),s);
        case Equal(a,b,s): Equal(canonicalExpression(a,module,entry,locals),canonicalExpression(b,module,entry,locals),s);
        case Call(name,args,s):
            var resolved=name;
            if(name.indexOf(".")<0 && locals.exists(name)) resolved=module==entry&&name=="main"?"main":module+"."+name;
            Call(resolved,[for(a in args) canonicalExpression(a,module,entry,locals)],s);
    }
    static function scanStatement(s,dependencies):Void switch s {
        case VarDeclaration(_,_,e,_), Return(e,_): scanExpression(e,dependencies);
        case If(c,y,n,_): scanExpression(c,dependencies);for(x in y)scanStatement(x,dependencies);for(x in n)scanStatement(x,dependencies);
    }
    static function scanExpression(e,dependencies):Void switch e {
        case Add(a,b,_),Sub(a,b,_),Less(a,b,_),LessEqual(a,b,_),Equal(a,b,_):scanExpression(a,dependencies);scanExpression(b,dependencies);
        case Call(name,args,_): var dot=name.indexOf(".");if(dot>0)dependencies.set(name.substr(0,dot),true);for(a in args)scanExpression(a,dependencies);
        default:
    }
    static function owner(name:String,entry:String):String { var dot=name.indexOf("."); return dot<0?entry:name.substr(0,dot); }
}
