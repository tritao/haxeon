struct Nested {
  public var x:Int;
  public function new(x:Int) this.x = x;
  public function bump():Void x++;
  public function bumpAndCall(callback:Void->Void):Void { x++; callback(); }
  public function bumpAndThrow():Void { x++; throw "done"; }
  public function bumpTimes(n:Int):Void { if (n > 0) { x++; bumpTimes(n - 1); } }
  public function bumpGeneric<T>(unused:T):Void x++;
}

struct Value {
  public var child:Nested;
  public var maybe:Null<Nested>;
  public var label:String;
  public function new(x:Int, label:String) {
    child = new Nested(x);
    maybe = null;
    this.label = label;
  }
  public function bumpMaybe():Void { if (maybe != null) maybe.x++; }
}

class Holder {
  public var value:Null<Value>;
  public function new() {}
  public function method():Int return 1;
}
class Derived extends Holder {
  public function new() super();
}

struct Container {
  public var value:Null<Value>;
  public function new(value:Null<Value>) this.value = value;
}
struct Immutable {
  public final x:Int;
  public function new(x:Int) this.x = x;
}
class ImmutableHolder {
  public final value:Null<Immutable>;
  public function new(value:Null<Immutable>) this.value = value;
}

function readX(value:Null<Value>):Int return value == null ? -1 : value.child.x;
function identity<T>(value:T):T return value;
function force(value:Null<Value>):Int {
  var present:Value = cast value;
  return present.child.x;
}

function main():Int {
  var immutable = new ImmutableHolder(new Immutable(42));
  var immutableCopy:Null<Immutable> = identity(immutable.value);
  if (immutableCopy == null || immutableCopy.x != 42 || haxeon.Structural.copy(immutableCopy).x != 42) return 34;
  var holder = new Holder();
  var derived = new Derived();
  derived.value = new Value(40, "inherited");
  if (readX(derived.value) != 40) return 19;
  derived.value = null;
  if (derived.value != null) return 20;
  if (holder.value != null || readX(holder.value) != -1) return 1;
  var original = new Value(7, "first");
  holder.value = original;
  if (Reflect.fields(holder).join(",") != "value") return 24;
  var reflected:Null<Value> = cast Reflect.field(holder, "value");
  if (readX(reflected) != 7) return 25;
  if (!Reflect.hasField(holder, "value") || Reflect.hasField(holder, "$inline:5:value:present") || Reflect.hasField(holder, "method")) return 26;
  Reflect.setField(holder, "value", null);
  if (holder.value != null) return 27;
  Reflect.setField(holder, "value", new Value(7, "reflection"));
  var reflectedCopy:Holder = cast Reflect.copy(holder);
  if (readX(reflectedCopy.value) != 7) return 28;
  if (!Reflect.deleteField(holder, "value") || holder.value != null) return 29;
  holder.value = original;
  original.child.x = 8;
  if (readX(holder.value) != 7) return 2;

  var copied = holder.value;
  if (copied != null) copied.child.x = 9;
  if (readX(holder.value) != 7 || readX(copied) != 9) return 3;
  if (holder.value != null) holder.value.child.x = 10;
  if (readX(holder.value) != 10 || readX(copied) != 9) return 4;
  if (holder.value != null) {
    if (holder.value.child.x++ != 10 || holder.value.child.x != 11) return 13;
    holder.value.child.x += 2;
    if (holder.value.child.x != 13) return 14;
  }
  if (holder.value == null || holder.value.child.x != 13) return 15;
  if (holder.value != null) {
    holder.value.child = new Nested(10);
    holder.value.maybe = new Nested(30);
  }
  if (holder.value == null || holder.value.maybe == null || holder.value.maybe.x != 30) return 16;
  if (holder.value != null && holder.value.maybe != null) holder.value.maybe.x = 31;
  if (holder.value == null || holder.value.maybe == null || holder.value.maybe.x != 31) return 17;
  if (holder.value != null) holder.value.bumpMaybe();
  if (holder.value == null || holder.value.maybe == null || holder.value.maybe.x != 32) return 30;
  if (holder.value != null) holder.value.maybe = null;
  var generic:Null<Value> = identity(holder.value);
  if (readX(generic) != 10) return 5;

  var values:Array<Null<Value>> = [null, holder.value];
  values[4] = new Value(14, "fourteen");
  if (values[0] != null || values[2] != null || values[3] != null || readX(values[1]) != 10 || readX(values[4]) != 14) return 6;
  var element = values[1];
  if (element != null) element.child.x = 11;
  if (readX(values[1]) != 10 || readX(element) != 11) return 7;
  if (values[1] != null) values[1].child.x = 12;
  if (readX(values[1]) != 12) return 8;
  values[1] = null;
  holder.value = null;
  if (values[1] != null || holder.value != null || readX(copied) != 9) return 9;
  try {
    force(holder.value);
    return 10;
  } catch (error:Dynamic) {}
  var first = new Container(new Value(20, "nested"));
  var second = first;
  if (first != second) return 35;
  if (second.value != null) second.value.child.x = 21;
  if (readX(first.value) != 20 || readX(second.value) != 21 || first == second) return 11;
  second.value = null;
  if (second.value != null || readX(first.value) != 20) return 12;
  if (first.value != null) first.value.child.bump();
  if (readX(first.value) != 21) return 18;
  var watched = new Holder();
  watched.value = new Value(7, "watched");
  var seen = 0;
  if (watched.value != null) watched.value.child.bumpAndCall(function() seen = readX(watched.value));
  if (seen != 8 || readX(watched.value) != 8) return 21;
  try {
    if (watched.value != null) watched.value.child.bumpAndThrow();
  } catch (error:Dynamic) {}
  if (readX(watched.value) != 9) return 22;
  if (watched.value != null) watched.value.child.bumpTimes(3);
  if (readX(watched.value) != 12) return 23;
  if (watched.value != null) watched.value.child.bumpGeneric(1);
  if (readX(watched.value) != 13) return 31;
  if (watched.value != null && haxeon.Structural.assignChanged(watched.value.child, new Nested(13), new Nested(17)) != 1) return 32;
  if (readX(watched.value) != 17) return 33;
  return 42;
}
