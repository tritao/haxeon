package compiler.hl;

import compiler.hl.HlCode.HlTypeDef;
import compiler.ir.Ir.IrType;

class HlSymbolTable {
    public final ints:Array<Int> = [];
    public final strings:Array<String> = [];
    public final types:Array<HlTypeDef> = [];
    final intIndices:Map<Int,Int> = [];
    final stringIndices:Map<String,Int> = [];
    final typeIndices:Map<String,Int> = [];

    public function new() {}
    public function internInt(value:Int):Int {
        var found=intIndices.get(value);if(found!=null)return found;
        var index=ints.length;ints.push(value);intIndices.set(value,index);return index;
    }
    public function internString(value:String):Int {
        var found=stringIndices.get(value);if(found!=null)return found;
        var index=strings.length;strings.push(value);stringIndices.set(value,index);return index;
    }
    public function internType(type:IrType):Int {
        var key=typeKey(type),found=typeIndices.get(key);if(found!=null)return found;
        var index=types.length;types.push(Simple(switch type {case Void:HlType.Void;case I32:HlType.I32;case Bool:HlType.Bool;}));typeIndices.set(key,index);return index;
    }
    public function internFunction(arguments:Array<IrType>,result:IrType):Int {
        var key='fun(${[for(a in arguments)typeKey(a)].join(",")})->${typeKey(result)}',found=typeIndices.get(key);if(found!=null)return found;
        var args=[for(a in arguments)internType(a)],ret=internType(result),index=types.length;
        types.push(Function(args,ret));typeIndices.set(key,index);return index;
    }
    static function typeKey(type:IrType):String return switch type {case Void:"void";case I32:"i32";case Bool:"bool";};
}
