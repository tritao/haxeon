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
struct NativeShape {
  public var narrow:Int16;
  public var unsigned:UInt8;
  public var fraction:Float32;
  public function new(narrow:Int, fraction:Float) { this.narrow = cast narrow; this.unsigned = 0; this.fraction = cast fraction; }
}
@:structural
struct FlatPoint {
  public final x:Float;
  public final y:Float;
  public function new(x:Float, y:Float) { this.x = x; this.y = y; }
}
@:structural
class PointHolder {
  public final point:FlatPoint;
  public function new(point:FlatPoint) this.point = point;
}
@:structural
struct Choice {
  public final n:Int;
  public final text:String;
  public function new(n:Int, text:String) { this.n = n; this.text = text; }
}
class Chooser {
  public var fallback:Choice;
  public function new() fallback = new Choice(1, "fallback");
  public function choose(value:Null<Choice>, ?preferred:Choice):Choice {
    var result = value == null ? fallback : value;
    return preferred == null ? result : preferred;
  }
}
class VirtualChooser {
  public function new() {}
  public function choose(value:Null<Choice>):Int return value == null ? 0 : value.n;
}
class OtherChooser extends VirtualChooser {
  public function new() super();
  override public function choose(value:Null<Choice>):Int return value == null ? 1 : value.n + 1;
}
class ChoiceBox {
  public var value:Null<Choice>;
  public function new(value:Null<Choice>) this.value = value;
}
function mergedChoiceAround(value:Null<Choice>, fallback:Choice, callback:Void->Void):Choice {
  var saved = mergedChoice(value, fallback);
  callback();
  return saved;
}
class ChoiceEffects {
  public static var count:Int = 0;
  public static function preferred(value:Choice):Choice { count++; return value; }
}
function makeChoice(n:Int, text:String):Choice return new Choice(n, text);
function mergedChoice(value:Null<Choice>, fallback:Choice):Choice
  return value == null ? fallback : makeChoice(value.n, value.text);
function applyChoice(chooser:Chooser, value:Choice):Int return chooser.choose(value, value).n;
function applyVirtualChoice(chooser:VirtualChooser, value:Null<Choice>):Int return chooser.choose(value);
function invokeNullChooser(chooser:Chooser, value:Choice):Int return chooser.choose(value, ChoiceEffects.preferred(value)).n;
class NativeHolder {
  public var value:Null<NativeShape>;
  public function new() {}
}
function changeNative(value:Null<NativeShape>, number:Int, fraction:Float):Null<NativeShape> {
  if (value != null) { value.narrow = cast number; value.unsigned = cast number; value.fraction = cast fraction; }
  return value;
}
function changeNativeAround(value:Null<NativeShape>, callback:Void->Void):Null<NativeShape> {
  try { if (value != null) value.narrow = cast 65535; callback(); } catch (_:Dynamic) {}
  return value;
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
function plainValue(v:Value):Int return v.n;
function relayValue(v:Null<Value>):Int return v == null ? 0 : plainValue(v);
function relayTypedValue(v:Null<Value>):Int {
  var callback:Value->Int = plainValue;
  return v == null ? 0 : callback(v);
}
function mutateValue(v:Value, callback:Void->Void):Int { callback(); v.n++; return v.n; }
function relaySnapshot(v:Null<Value>, callback:Void->Void):Int {
  if (v == null) return 0;
  return mutateValue(v, callback) * 100 + v.n;
}
function sameValue(v:Null<Value>, expected:Value):Bool return v == expected;
function plainWithIgnored(v:Value, ignored:Int):Int return v.n;
function invokeSideEffect(callback:Void->Void):Int { callback(); return 0; }
function snapshotBeforeLaterArgument(v:Null<Value>):Int {
  if (v == null) return 0;
  return plainWithIgnored(v, invokeSideEffect(function() { v.n = 9; }));
}
function main():Int {
  var chooser = new Chooser(), choice = new Choice(42, "managed"), choiceBefore = hl.Gc.totalAllocated(), choiceTotal = 0;
  for (i in 0...10000) choiceTotal += applyChoice(chooser, choice);
  if (choiceTotal != 420000 || hl.Gc.totalAllocated() - choiceBefore > 4096) return 37;
  var mergedBefore = hl.Gc.totalAllocated(), mergedTotal = 0;
  for (i in 0...10000) mergedTotal += mergedChoice(choice, chooser.fallback).n;
  if (mergedTotal != 420000 || hl.Gc.totalAllocated() - mergedBefore > 4096) return 45;
  if (mergedChoice(null, chooser.fallback).n != 1) return 46;
  var choiceBox = new ChoiceBox(choice);
  var mergedSnapshot = mergedChoiceAround(choiceBox.value, chooser.fallback, function() { choiceBox.value = null; hl.Gc.major(); });
  if (mergedSnapshot.n != 42 || mergedSnapshot.text != "managed" || choiceBox.value != null) return 47;
  try { mergedChoiceAround(choice, chooser.fallback, function() { throw "expected"; }); return 48; }
  catch (error:Dynamic) { if (error != "expected") return 49; }
  if (chooser.choose(null).n != 1 || chooser.choose(choice).text != "managed") return 38;
  var virtualChooser:VirtualChooser = new OtherChooser();
  if (applyVirtualChoice(virtualChooser, choice) != 43 || applyVirtualChoice(virtualChooser, null) != 1) return 39;
  try { invokeNullChooser(null, choice); return 40; } catch (_:Dynamic) {}
  if (ChoiceEffects.count != 1) return 41;

  var pointHolder = new PointHolder(new FlatPoint(1, 2));
  var expectedHash = haxeon.Structural.hash(pointHolder), hashBefore = hl.Gc.totalAllocated(), hashTotal = 0;
  var pointHash = haxeon.Structural.mix(haxeon.Structural.mix(17, haxeon.Structural.hashFloat(1)), haxeon.Structural.hashFloat(2));
  if (expectedHash != haxeon.Structural.mix(17, pointHash)) return 32;
  for (i in 0...10000) if (haxeon.Structural.hash(pointHolder) == expectedHash) hashTotal++;
  if (hashTotal != 10000 || hl.Gc.totalAllocated() - hashBefore > 4096) return 31;
  var nativeHolder = new NativeHolder();
  nativeHolder.value = new NativeShape(1, 0);
  var nativeBefore = hl.Gc.totalAllocated(), nativeTotal = 0;
  for (i in 0...10000) {
    var updated = changeNative(nativeHolder.value, 65535, 1.00000003);
    if (updated != null && (cast updated.narrow:Int) == -1 && (cast updated.unsigned:Int) == 255 && updated.fraction == 1.0) nativeTotal++;
  }
  if (nativeTotal != 10000 || hl.Gc.totalAllocated() - nativeBefore > 4096) return 27;
  if (nativeHolder.value == null || (cast nativeHolder.value.narrow:Int) != 1) return 28;
  var nativeSnapshot = changeNativeAround(nativeHolder.value, function() { nativeHolder.value = null; hl.Gc.major(); throw "expected"; });
  if (nativeSnapshot == null || (cast nativeSnapshot.narrow:Int) != -1 || nativeHolder.value != null) return 29;
  if (changeNative(null, 1, 0) != null) return 30;
  var a = new Holder(), b = new Holder();
  a.value = new Value(42, "managed");
  var equal:Null<Value> = new Value(42, "managed");
  if (a.value != equal) return 24;
  var firstValue:Value = cast a.value, secondValue:Value = cast equal;
  if (haxeon.Structural.hash(firstValue) != haxeon.Structural.hash(secondValue)) return 25;
  var expectedValue:Value = cast a.value;
  var equalityBefore = hl.Gc.totalAllocated(), equalityTotal = 0;
  for (i in 0...10000) {
    if (sameValue(a.value, expectedValue)) equalityTotal++;
    equalityTotal += relayValue(a.value) + relayTypedValue(a.value);
  }
  if (equalityTotal != 850000 || hl.Gc.totalAllocated() - equalityBefore > 4096) return 33;
  if (sameValue(null, expectedValue) || relayValue(null) != 0 || relayTypedValue(null) != 0) return 34;
  var valueSnapshot = relaySnapshot(a.value, function() { a.value = null; hl.Gc.major(); });
  if (valueSnapshot != 4342 || a.value != null) return 35;
  if (snapshotBeforeLaterArgument(new Value(42, "managed")) != 42) return 36;
  a.value = new Value(42, "managed");
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
