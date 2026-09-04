package compiler.hl;

import compiler.ir.IrFunction;

class HlFunctionCache {
    public final indices:Map<String,Int> = [];
    public final slots:Array<String> = [];
    public final functions:Map<String,IrFunction> = [];
    public final signatures:Map<String,String> = [];

    public function new() { indices.set("__exit",0); }

    public function update(incoming:Array<IrFunction>):Void {
        for(fn in incoming) {
            if(!indices.exists(fn.name)){indices.set(fn.name,slots.length+1);slots.push(fn.name);}
            functions.set(fn.name,fn);signatures.set(fn.name,signature(fn));
        }
    }

    public function ordered():Array<IrFunction> return [for(name in slots) functions.get(name)];
    public static function signature(fn:IrFunction):String return "("+[for(a in fn.arguments)Std.string(a.type)].join(",")+")->"+Std.string(fn.result);
}
