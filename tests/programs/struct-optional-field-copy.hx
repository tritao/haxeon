struct Child {
  public var number:Int;
  public var text:String;
  public function new(number:Int, text:String) { this.number = number; this.text = text; }
}
struct Value {
  public var child:Null<Child>;
  public var label:String;
  public function new(child:Null<Child>, label:String) { this.child = child; this.label = label; }
}
class Holder {
  public var first:Null<Value>;
  public var second:Null<Value>;
  public function new() {}
}
class Derived extends Holder { public function new() super(); }
class State {
  public static var order = "";
  public static var victim:Holder;
}
function destination(value:Holder):Holder { State.order += "d"; return value; }
function source(value:Holder):Holder { State.order += "s"; return value; }
function reenter(value:Holder):Holder {
  State.order += "r";
  State.victim.second = null;
  return value;
}
function fail(value:Holder):Holder { State.order += "e"; if (State.order == "de") throw "expected"; return value; }
function copy(target:Holder, input:Holder):Void target.first = input.first;
function main():Int {
  var a = new Holder(), b = new Derived();
  a.first = new Value(new Child(7, "managed"), "present");
  destination(b).first = source(a).first;
  if (State.order != "ds" || b.first == null || b.first.child == null || b.first.child.text != "managed") return 1;
  if (a.first != null && a.first.child != null) a.first.child.number = 9;
  if (b.first == null || b.first.child == null || b.first.child.number != 7) return 2;
  b.second = b.first;
  b.first = b.first;
  if (b.second == null || b.second.child == null || b.second.child.number != 7) return 3;
  b.first = null;
  b.second = b.first;
  if (b.second != null) return 4;
  a.first = new Value(null, "nested absent");
  b.first = a.first;
  if (b.first == null || b.first.child != null || b.first.label != "nested absent") return 5;
  a.first = new Value(new Child(11, "live"), "outer");
  State.victim = b;
  b.second = a.first;
  State.order = "";
  destination(b).first = reenter(a).first;
  if (State.order != "dr" || b.second != null || b.first == null || b.first.child == null || b.first.child.number != 11) return 6;
  var get:Holder->Holder = source;
  var put:Holder->Holder = destination;
  State.order = "";
  put(b).second = get(a).first;
  if (State.order != "ds" || b.second == null || b.second.child == null || b.second.child.text != "live") return 15;
  State.order = "";
  try { destination(b).first = fail(a).first; return 7; } catch (error:Dynamic) {
    if (error != "expected" || State.order != "de" || b.first == null || b.first.child == null || b.first.child.number != 11) return 8;
  }
  #if !wasm
  var missing:Holder = null;
  State.order = "";
  try { destination(b).first = source(missing).first; return 9; } catch (_:Dynamic) {
    if (State.order != "ds" || b.first == null || b.first.child == null || b.first.child.number != 11) return 10;
  }
  State.order = "";
  try { destination(missing).first = source(a).first; return 11; } catch (_:Dynamic) {
    if (State.order != "ds") return 12;
  }
  #end
  hl.Gc.major();
  if (b.first == null || b.first.child == null || b.first.child.text != "live") return 13;
  var before = hl.Gc.totalAllocated();
  for (i in 0...10000) copy(b, a);
  var allocated = hl.Gc.totalAllocated() - before;
  if (allocated > 4096 || b.first == null || b.first.child == null || b.first.child.number != 11) return 14;
  a.first = null;
  before = hl.Gc.totalAllocated();
  for (i in 0...10000) copy(b, a);
  allocated = hl.Gc.totalAllocated() - before;
  if (allocated > 4096 || b.first != null) return 16;
  return 42;
}
