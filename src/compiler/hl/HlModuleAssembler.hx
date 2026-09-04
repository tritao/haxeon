package compiler.hl;

import compiler.ir.HlLower;
import compiler.ir.Ir.IrProgram;

typedef HlAssemblyResult = {
    final module:HlCode;
    final changedFunctions:Array<Int>;
    final changedSlots:Array<Int>;
    final functionIndices:Map<String,Int>;
    final requiresReload:Bool;
    final revision:Int;
    final baseInts:Int; final baseFloats:Int; final baseStrings:Int; final baseTypes:Int;
}

class HlModuleAssembler {
    public final symbols = new HlSymbolTable();
    public final cache:HlFunctionCache;
    var initialized:Bool=false;
    var revision:Int=0;
    var publishedInts=0; var publishedFloats=0; var publishedStrings=0; var publishedTypes=0;

    public function new(?stableIds:Map<String,Int>) { cache=new HlFunctionCache(stableIds); }

    public function assemble(program:IrProgram, regenerated:Array<String>, signatureChanges:Array<String>):HlAssemblyResult {
        cache.update(program.functions);
        var ordered=new IrProgram(program.entryPoint);
        ordered.natives=program.natives;
        ordered.functions=cache.ordered();
        var layout:Map<String,Int>=[],next=0;
        for(native in ordered.natives)layout.set(native.name,next++);
        for(name in cache.slots)layout.set(name,next++);
        var changed:Array<Int>=[], changedSlots:Array<Int>=[];
        if(initialized) for(name in regenerated) {
            var index=layout.get(name), stableId=cache.stableIds.get(name);
            if(index!=null&&stableId!=null){changedSlots.push(index);changed.push(stableId);}
        }
        changed.sort(function(a,b)return a-b);changedSlots.sort(function(a,b)return a-b);
        var reload=initialized && signatureChanges.length>0;
        var module=HlLower.lowerStable(ordered,symbols,layout);
        var baseInts=publishedInts,baseFloats=publishedFloats,baseStrings=publishedStrings,baseTypes=publishedTypes;
        publishedInts=module.ints.length;publishedFloats=module.floats.length;publishedStrings=module.strings.length;publishedTypes=module.types.length;
        revision++;
        initialized=true;
        return {module:module,changedFunctions:changed,changedSlots:changedSlots,functionIndices:layout,requiresReload:reload,revision:revision,
            baseInts:baseInts,baseFloats:baseFloats,baseStrings:baseStrings,baseTypes:baseTypes};
    }
}
