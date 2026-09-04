package compiler.hl;

import compiler.ir.IrFunction;

class HlFunctionCache {
    public final indices:Map<String,Int> = [];
    public final stableIds:Map<String,Int> = [];
    public final slots:Array<String> = [];
    public final functions:Map<String,IrFunction> = [];
    public final signatures:Map<String,String> = [];

    var nextStableId:Int = 0x10000;
    var nextIndex:Int=1;

    public function new(?existingStableIds:Map<String,Int>) {
        indices.set("__exit",0);
        if(existingStableIds!=null)for(name=>id in existingStableIds){stableIds.set(name,id);if(id>=nextStableId)nextStableId=id+1;}
    }

    public function update(incoming:Array<IrFunction>):Void {
        for(fn in incoming) {
            if(!indices.exists(fn.name)){
                indices.set(fn.name,nextIndex++);
                if(!stableIds.exists(fn.name))stableIds.set(fn.name,nextStableId++);
                slots.push(fn.name);
            }
            functions.set(fn.name,fn);signatures.set(fn.name,signature(fn));
        }
    }

    public function registerNative(name:String):Void {if(!indices.exists(name))indices.set(name,nextIndex++);}

    public function ordered():Array<IrFunction> return [for(name in slots) functions.get(name)];
    public static function signature(fn:IrFunction):String return "("+[for(a in fn.arguments)Std.string(a.type)].join(",")+")->"+Std.string(fn.result);
}
