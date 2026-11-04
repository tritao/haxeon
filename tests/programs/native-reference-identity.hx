extern class NativeIdentityProbe {
 @:hlNative("haxeon_runtime", "__reference_identity")
 public static function same(left:Dynamic, right:Dynamic):Bool;
}

class ReferenceIdentityCensus {
 static var left:Dynamic;
 static var right:Dynamic;
 static var indirect:Dynamic->Dynamic->Bool;
 public static function prepare():Void {
  left = Std.string(123); right = Std.string(123); indirect = NativeIdentityProbe.same;
 }
 public static function perform(n:Int):Int {
  var count = 0;
  var call = indirect;
  for (_ in 0...n) if (!call(left, right) && call(left, left)) count++;
  return count;
 }
}

function main():Int {
 var left:Dynamic = Std.string(123), right:Dynamic = Std.string(123);
 var indirect:Dynamic->Dynamic->Bool = NativeIdentityProbe.same;
 if (NativeIdentityProbe.same(left, right)) return 1;
 if (indirect(left, right)) return 2;
 if (!indirect(left, left)) return 3;
 ReferenceIdentityCensus.prepare();
 #if !wasm
 var before = hl.Gc.totalAllocated();
 #end
 if (ReferenceIdentityCensus.perform(1024) != 1024) return 4;
 #if !wasm
 if (hl.Gc.totalAllocated() != before) return 5;
 #end
 return 42;
}
