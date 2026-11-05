interface IdentityView { function number():Int; }

class IdentityObject implements IdentityView {
 public var value:Int;
 public function new(value:Int) this.value = value;
 public function number():Int return value;
 public function equals(other:IdentityObject):Bool return value == other.value;
 // A runtime comparison hook cannot replace language identity for a class.
 public function __compare(other:IdentityObject):Int return 0;
}

struct IdentityRecord implements Equatable {
 public final value:Int;
 public function new(value:Int) this.value=value;
}

class IdentityClassCensus {
 static var left:IdentityObject;
 static var right:IdentityObject;
 public static function prepare():Void { left = new IdentityObject(7); right = new IdentityObject(7); }
 public static function perform(count:Int):Int {
  var result = 0;
  for (_ in 0...count) if (left == left && left != right) result++;
  return result;
 }
}

function main():Int {
 var a = new IdentityObject(7), b = new IdentityObject(7);
 if (a == b || a != a || !a.equals(b)) return 1;
 var av:IdentityView=a, alias:IdentityView=a, bv:IdentityView=b;
 if (av != alias || av == bv || av != a || bv != b) return 4;
 var da:Dynamic=a, db:Dynamic=b;
 if (da == db || da != da) return 5;
 var nil:Null<IdentityObject>=null, otherNil:Null<IdentityObject>=null;
 if (nil != otherNil || a == nil || nil == a) return 6;
 var x:Equatable=new IdentityRecord(1), y:Equatable=new IdentityRecord(1), same=x;
 if (x == y || x != same) return 7;
 var dx:Dynamic=x, dy:Dynamic=y;
 if (!(dx == dy)) return 8;
 if (new IdentityRecord(1) != new IdentityRecord(1)) return 9;
 var objects=new haxe.ds.ObjectMap<IdentityObject,Int>();
 objects.set(a,1); objects.set(b,2);
 if (objects.get(a)!=1 || objects.get(b)!=2) return 10;
 if (haxeon.Equality.equals(a,b) || !haxeon.Equality.equals(a,a)) return 11;
 if (haxeon.Equality.equals(av,bv) || !haxeon.Equality.equals(av,alias)) return 12;
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
