package compiler.hl;

import haxe.io.Bytes;
import haxe.io.BytesOutput;
import compiler.hl.HlCode.HlTypeDef;

class HlPatchWriter {
    public static inline final VERSION=2;

    public static function encode(code:HlCode, changedFunctions:Array<Int>, baseRevision:Int, revision:Int,
        baseInts:Int=0, baseFloats:Int=0, baseStrings:Int=0, baseTypes:Int=0):Bytes {
        if(baseRevision<0 || revision<=baseRevision)throw "Invalid patch revision range";
        var selected:Array<HlFunction>=[];
        for(index in changedFunctions) {
            var found=null;
            for(fn in code.functions)if(fn.functionIndex==index){found=fn;break;}
            if(found==null)throw 'Patch references missing function $index';
            selected.push(found);
        }
        var out=new BytesOutput();out.bigEndian=false;
        out.writeString("HLP");out.writeByte(VERSION);writeIndex(out,baseRevision);writeIndex(out,revision);
        checkBase(baseInts,code.ints.length);writeIndex(out,baseInts);writeIndex(out,code.ints.length-baseInts);for(i in baseInts...code.ints.length)out.writeInt32(code.ints[i]);
        checkBase(baseFloats,code.floats.length);writeIndex(out,baseFloats);writeIndex(out,code.floats.length-baseFloats);for(i in baseFloats...code.floats.length)out.writeDouble(code.floats[i]);
        checkBase(baseStrings,code.strings.length);writeIndex(out,baseStrings);writeIndex(out,code.strings.length-baseStrings);for(i in baseStrings...code.strings.length){var b=Bytes.ofString(code.strings[i]);writeIndex(out,b.length);out.write(b);}
        checkBase(baseTypes,code.types.length);writeIndex(out,baseTypes);writeIndex(out,code.types.length-baseTypes);for(i in baseTypes...code.types.length)writeType(out,code.types[i]);
        writeIndex(out,selected.length);
        for(fn in selected){var bytes=HlWriter.encodeFunction(fn);writeIndex(out,bytes.length);out.write(bytes);}
        return out.getBytes();
    }
    static function checkBase(base:Int,total:Int):Void if(base<0||base>total)throw "Invalid HLP symbol base";

    static function writeType(out:BytesOutput,type:HlTypeDef):Void switch type {
        case Simple(kind):out.writeByte(kind);
        case Function(args,result):out.writeByte(HlType.Fun);out.writeByte(args.length);for(a in args)writeSignedIndex(out,a);writeSignedIndex(out,result);
    }
    static function writeIndex(out:BytesOutput,v:Int):Void {if(v<0)throw 'Negative patch index $v';writeSignedIndex(out,v);}
    static function writeSignedIndex(out:BytesOutput,v:Int):Void out.write(HlWriter.encodeIndex(v));
}
