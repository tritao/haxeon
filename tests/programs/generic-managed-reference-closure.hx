struct ManagedClosureAnchor { public final id:Int; public function new(id:Int) this.id = id; }
struct ManagedClosureValue {
 public var number:Int;
 public var text:String;
 public function new(number:Int, text:String) { this.number = number; this.text = text; }
}
class ManagedClosureHolder<A,B> {
 public var anchor:A;
 public var value:B;
 public var storage:Array<B>;
 public function new(anchor:A, value:B) { this.anchor = anchor; this.value = value; storage = null; }
}
function managedClosureIdentity(value:ManagedClosureValue):ManagedClosureValue return value;
class ManagedClosureCensus {
 static var holder:ManagedClosureHolder<ManagedClosureAnchor,ManagedClosureValue->ManagedClosureValue>;
 static var expected:String;
 public static function prepare():Void {
  expected = "value";
  holder = new ManagedClosureHolder<ManagedClosureAnchor,ManagedClosureValue->ManagedClosureValue>(new ManagedClosureAnchor(1), managedClosureIdentity);
  var erased:ManagedClosureHolder<Dynamic,Dynamic> = holder;
  erased.value = managedClosureIdentity;
 }
 public static function perform(n:Int):Int {
  var sum = 0;
  for (_ in 0...n) {
   var result = holder.value(new ManagedClosureValue(1,"value"));
   if (result.text != expected) return -1;
   sum += result.number;
  }
  return sum;
 }
 public static function literalOnly(n:Int):Int {
  var sum = 0;
  for (_ in 0...n) if ("loop-only".length == 9) sum++;
  return sum;
 }
}
function main():Int {
 ManagedClosureCensus.prepare();
 #if !wasm
 hl.Gc.major();
 var before = hl.Gc.totalAllocated();
 #end
 if (ManagedClosureCensus.perform(8) != 8 || ManagedClosureCensus.perform(1024) != 1024) return 1;
 #if !wasm
 if (hl.Gc.totalAllocated() != before) return 2;
 #end
 return 42;
}
