import haxe.io.Bytes;

@:hlNative("haxeon_runtime", "structGetUtf8")
extern function readUtf8Field(record:Bytes, offset:Int, nullable:Bool):Null<String>;
class Utf8FieldStorage {public static var value:Null<String>;}
function copy(pointer:Int):Int {
    var record=Bytes.alloc(8);
    record.setInt32(4,pointer);
    Utf8FieldStorage.value=readUtf8Field(record,4,false);
    if(Utf8FieldStorage.value!="é🙂") return 1;
    record.setInt32(4,0);
    if(readUtf8Field(record,4,true)!=null) return 2;
    return 42;
}
function verify():Int return Utf8FieldStorage.value=="é🙂" ? 42 : 3;
function main():Int return 42;
