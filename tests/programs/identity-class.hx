import haxeon.Identity;

class IdentityValue implements Equatable {
 public var value:Int;
 public function new(value:Int) this.value = value;
 public function equals(other:IdentityValue):Bool return value == other.value;
}

class IdentityClassCensus {
 static var left:IdentityValue;
 static var right:IdentityValue;
 public static function prepare():Void { left = new IdentityValue(7); right = new IdentityValue(7); }
 public static function perform(count:Int):Int {
  var result = 0;
  for (_ in 0...count) if (Identity.same(left, left) && !Identity.same(left, right)) result++;
  return result;
 }
}

function main():Int {
 var a = new IdentityValue(7), b = new IdentityValue(7);
 if (!(a == b) || Identity.same(a, b) || !Identity.same(a, a)) return 1;
 IdentityClassCensus.prepare();
 #if !wasm
 var before = hl.Gc.totalAllocated();
 #end
 if (IdentityClassCensus.perform(1024) != 1024) return 2;
 #if !wasm
 if (hl.Gc.totalAllocated() != before) return 3;
 #end
 return 42;
}
