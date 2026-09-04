package compiler.hl;

import haxe.io.Bytes;
import haxe.io.BytesOutput;
import compiler.hl.HlCode.HlTypeDef;

class HlPatchWriter {
    public static inline final VERSION=1;

    public static function encode(code:HlCode, changedFunctions:Array<Int>, baseRevision:Int, revision:Int):Bytes {
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
        writeIndex(out,code.ints.length);for(v in code.ints)out.writeInt32(v);
        writeIndex(out,code.floats.length);for(v in code.floats)out.writeDouble(v);
        writeIndex(out,code.strings.length);for(v in code.strings){var b=Bytes.ofString(v);writeIndex(out,b.length);out.write(b);}
        writeIndex(out,code.types.length);for(t in code.types)writeType(out,t);
        writeIndex(out,selected.length);
        for(fn in selected){var bytes=HlWriter.encodeFunction(fn);writeIndex(out,bytes.length);out.write(bytes);}
        return out.getBytes();
    }

    static function writeType(out:BytesOutput,type:HlTypeDef):Void switch type {
        case Simple(kind):out.writeByte(kind);
        case Function(args,result):out.writeByte(HlType.Fun);out.writeByte(args.length);for(a in args)writeSignedIndex(out,a);writeSignedIndex(out,result);
    }
    static function writeIndex(out:BytesOutput,v:Int):Void {if(v<0)throw 'Negative patch index $v';writeSignedIndex(out,v);}
    static function writeSignedIndex(out:BytesOutput,v:Int):Void out.write(HlWriter.encodeIndex(v));
}
