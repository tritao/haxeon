package compiler.hl;

import haxe.io.Bytes;
import haxe.io.BytesOutput;

class HlRuntimeIdentity {
    public static inline final VERSION=1;
    static var sequence=1;

    public static function createModuleId():Bytes {
        var out=Bytes.alloc(16), now=Date.now().getTime(), id=sequence++;
        out.setInt32(0,Std.int(now));out.setInt32(4,Std.int(now/4294967296.0));
        out.setInt32(8,Std.random(0x3FFFFFFF));out.setInt32(12,id);
        return out;
    }

    public static function encode(moduleId:Bytes, indices:Map<String,Int>, stableIds:Map<String,Int>):Bytes {
        if(moduleId.length!=16)throw "Module ID must contain 16 bytes";
        var names=[for(name in stableIds.keys())if(indices.exists(name))name];names.sort(Reflect.compare);
        var out=new BytesOutput();out.bigEndian=false;out.writeString("HLI");out.writeByte(VERSION);out.write(moduleId);
        out.writeInt32(names.length);
        for(name in names){out.writeInt32(stableIds.get(name));out.writeInt32(indices.get(name));}
        return out.getBytes();
    }
}
