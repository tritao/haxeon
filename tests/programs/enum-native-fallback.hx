#if !wasm
enum Opaque { Item(value:Int); }
enum Tags { A; B; }
@:hlNative("haxeon_runtime", "__dynamic_equal") extern function nativeEqual(a:Dynamic, b:Dynamic):Bool;
@:hlNative("haxeon_runtime", "__reflect_compare") extern function nativeCompare(a:Dynamic, b:Dynamic):Int;
@:hlNative("haxeon_runtime", "__array_index_of_any") extern function nativeIndex(values:Array<Dynamic>, value:Dynamic):Int;
#end
function main():Int {
 #if !wasm
 var value:Dynamic = Opaque.Item(1), tagA:Dynamic = Tags.A, tagB:Dynamic = Tags.B;
 var rejected = false;
 try { nativeEqual(value, value); } catch (_:Dynamic) { rejected = true; }
 if (!rejected || !nativeEqual(tagA, tagA) || nativeEqual(tagA, tagB)) return 1;
 rejected = false;
 try { nativeIndex([value], value); } catch (_:Dynamic) { rejected = true; }
 if (!rejected) return 2;
 if (nativeCompare(value, value) != 0xAABBCCDD) return 3;
 #end
 return 42;
}
