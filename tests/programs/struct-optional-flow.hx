@:structural
struct Child {
  public var text:String;
  public function new(text:String) this.text = text;
}
@:structural
struct Value {
  public var n:Int;
  public var child:Null<Child>;
  public function new(n:Int, text:String) { this.n = n; this.child = new Child(text); }
  public function incrementAndCall(callback:Void->Void):Void { n++; callback(); }
}
class Holder {
  public var value:Null<Value>;
  public function new() {}
}
class Processor {
  public function new() {}
  public function apply(v:Null<Value>):Int return number(v);
}
class OtherProcessor extends Processor {
  public function new() super();
  override public function apply(v:Null<Value>):Int return number(v) + 1;
}
function processor(other:Bool):Processor return other ? new OtherProcessor() : new Processor();
function identity(v:Null<Value>):Null<Value> return v;
function number(v:Null<Value>):Int return v == null ? 0 : v.n;
function text(v:Null<Value>):String return v == null || v.child == null ? "absent" : v.child.text;
function around(v:Null<Value>, callback:Void->Void):Null<Value> { callback(); return v; }
function recurse(v:Null<Value>, depth:Int):Int return depth == 0 ? number(v) : recurse(v, depth - 1);
function choose(v:Null<Value>, present:Bool):Null<Value> return present ? v : null;
function bump(v:Null<Value>):Null<Value> { if (v != null) v.n += 1; return v; }
function advance(v:Null<Value>, count:Int):Null<Value> {
  for (i in 0...count) if (v != null) v.n += 1;
  return v;
}
function chooseChanged(v:Null<Value>, present:Bool):Null<Value> {
  if (v != null) v.n += 1;
  return present ? v : null;
}
function copyThenMutate(v:Null<Value>):Int {
  var saved = v;
  if (v != null) v.n = 7;
  return number(saved) * 100 + number(v);
}
function changeChild(v:Null<Value>, label:String):Null<Value> {
  if (v != null && v.child != null) v.child.text = label;
  return v;
}
function catchAfterWrite(v:Null<Value>, callback:Void->Void):Null<Value> {
  try { if (v != null) v.n += 1; callback(); } catch (_:Dynamic) {}
  return v;
}
function methodAfterWrite(v:Null<Value>, callback:Void->Void):Null<Value> {
  try { if (v != null) v.incrementAndCall(callback); } catch (_:Dynamic) {}
  return v;
}
function main():Int {
  var a = new Holder(), b = new Holder();
  a.value = new Value(42, "managed");
  var equal:Null<Value> = new Value(42, "managed");
  if (a.value != equal) return 24;
  var firstValue:Value = cast a.value, secondValue:Value = cast equal;
  if (haxeon.Structural.hash(firstValue) != haxeon.Structural.hash(secondValue)) return 25;
  var before = hl.Gc.totalAllocated(), total = 0;
  for (i in 0...10000) {
    var local = a.value;
    b.value = identity(local);
    total += number(local);
  }
  var allocated = hl.Gc.totalAllocated() - before;
  if (total != 420000 || allocated > 4096) return 1;
  var call:Null<Value>->Null<Value> = identity;
  var offset = 2;
  var captured:Null<Value>->Int = function(v:Null<Value>):Int return v == null ? offset : v.n + offset;
  before = hl.Gc.totalAllocated();
  total = 0;
  for (i in 0...10000) total += number(call(a.value)) + captured(a.value);
  allocated = hl.Gc.totalAllocated() - before;
  if (total != 860000 || allocated > 4096) return 3;
  before = hl.Gc.totalAllocated();
  total = 0;
  for (i in 0...10000) {
    var chosen = choose(a.value, i % 2 == 0);
    b.value = chosen;
    total += number(chosen);
  }
  allocated = hl.Gc.totalAllocated() - before;
  if (total != 210000 || allocated > 4096) return 7;
  before = hl.Gc.totalAllocated();
  total = 0;
  for (i in 0...10000) total += number(bump(a.value));
  allocated = hl.Gc.totalAllocated() - before;
  if (total != 430000 || number(a.value) != 42 || allocated > 4096) return 8;
  before = hl.Gc.totalAllocated();
  total = 0;
  for (i in 0...1000) total += number(advance(a.value, 5));
  allocated = hl.Gc.totalAllocated() - before;
  if (total != 47000 || number(a.value) != 42 || allocated > 4096) return 9;
  before = hl.Gc.totalAllocated();
  total = 0;
  for (i in 0...1000) total += recurse(a.value, 5);
  allocated = hl.Gc.totalAllocated() - before;
  if (total != 42000 || allocated > 4096) return 20;
  before = hl.Gc.totalAllocated();
  total = 0;
  for (i in 0...10000) total += number(chooseChanged(a.value, i % 2 == 0));
  allocated = hl.Gc.totalAllocated() - before;
  if (total != 215000 || allocated > 4096) return 16;
  before = hl.Gc.totalAllocated();
  total = 0;
  for (i in 0...10000) total += copyThenMutate(a.value);
  allocated = hl.Gc.totalAllocated() - before;
  if (total != 42070000 || allocated > 4096) return 17;
  var changedLabel = "changed";
  before = hl.Gc.totalAllocated();
  for (i in 0...10000) b.value = changeChild(a.value, changedLabel);
  allocated = hl.Gc.totalAllocated() - before;
  if (allocated > 4096 || text(b.value) != "changed" || text(a.value) != "managed") return 18;
  var noop:Void->Void = function() {};
  before = hl.Gc.totalAllocated();
  total = 0;
  for (i in 0...10000) total += number(catchAfterWrite(a.value, noop));
  allocated = hl.Gc.totalAllocated() - before;
  if (total != 430000 || allocated > 4096) return 11;
  var thrownError = "expected";
  var raiser:Void->Void = function() { throw thrownError; };
  before = hl.Gc.totalAllocated();
  total = 0;
  for (i in 0...1000) total += number(catchAfterWrite(a.value, raiser));
  allocated = hl.Gc.totalAllocated() - before;
  if (total != 43000 || allocated > 4096) return 12;
  var direct = new Processor();
  before = hl.Gc.totalAllocated();
  total = 0;
  for (i in 0...10000) total += direct.apply(a.value);
  allocated = hl.Gc.totalAllocated() - before;
  if (total != 420000 || allocated > 4096) return 21;
  if (processor(true).apply(a.value) != 43 || processor(false).apply(a.value) != 42) return 22;
  #if !wasm
  var missingProcessor:Processor = null;
  try { missingProcessor.apply(a.value); return 23; } catch (_:Dynamic) {}
  #end
  var dynamicValue:Dynamic = a.value;
  var recovered:Null<Value> = cast dynamicValue;
  if (number(recovered) != 42 || text(recovered) != "managed") return 13;
  before = hl.Gc.totalAllocated();
  total = 0;
  for (i in 0...10000) total += number(recovered);
  allocated = hl.Gc.totalAllocated() - before;
  if (total != 420000 || allocated > 4096) return 14;
  var changed:Null<Value> = a.value;
  if (changed != null) changed.n = 45;
  var changedDynamic:Dynamic = changed;
  var changedBack:Null<Value> = cast changedDynamic;
  if (number(changedBack) != 45 || number(a.value) != 42) return 15;
  var absentDynamic:Dynamic = null;
  var absentBack:Null<Value> = cast absentDynamic;
  if (absentBack != null || number(absentBack) != 0) return 19;
  var afterCatch = catchAfterWrite(a.value, function() { a.value = null; hl.Gc.major(); throw "expected"; });
  if (number(afterCatch) != 43 || text(afterCatch) != "managed" || a.value != null) return 10;
  a.value = new Value(42, "managed");
  var afterMethod = methodAfterWrite(a.value, function() { a.value = null; hl.Gc.major(); throw "expected"; });
  if (number(afterMethod) != 43 || text(afterMethod) != "managed" || a.value != null) return 26;
  a.value = afterCatch;
  var snapshot = around(a.value, function() { a.value = null; hl.Gc.major(); });
  if (a.value != null || number(snapshot) != 43 || text(snapshot) != "managed" || recurse(snapshot, 5) != 43) return 4;
  a.value = snapshot;
  try {
    around(a.value, function() { a.value = null; throw "expected"; });
    return 5;
  } catch (error:Dynamic) {
    if (error != "expected" || a.value != null) return 6;
  }
  a.value = null;
  before = hl.Gc.totalAllocated();
  for (i in 0...10000) {
    var local = a.value;
    b.value = identity(local);
    total += number(local);
  }
  allocated = hl.Gc.totalAllocated() - before;
  if (b.value != null || allocated > 4096) return 2;
  return 42;
}
