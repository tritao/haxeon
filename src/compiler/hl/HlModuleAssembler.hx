package compiler.hl;

import compiler.ir.HlLower;
import compiler.ir.Ir.IrProgram;

typedef HlAssemblyResult = {
    final module:HlCode;
    final changedFunctions:Array<Int>;
    final requiresReload:Bool;
}

class HlModuleAssembler {
    public final symbols = new HlSymbolTable();
    public final cache = new HlFunctionCache();
    var initialized:Bool=false;

    public function new() {}

    public function assemble(program:IrProgram, regenerated:Array<String>, signatureChanges:Array<String>):HlAssemblyResult {
        cache.update(program.functions);
        var ordered=new IrProgram(program.entryPoint);
        ordered.natives=program.natives;
        ordered.functions=cache.ordered();
        var changed=[];
        if(initialized) for(name in regenerated) { var index=cache.indices.get(name);if(index!=null)changed.push(index); }
        changed.sort(function(a,b)return a-b);
        var reload=initialized && signatureChanges.length>0;
        var module=HlLower.lowerStable(ordered,symbols,cache.indices);
        initialized=true;
        return {module:module,changedFunctions:changed,requiresReload:reload};
    }
}
