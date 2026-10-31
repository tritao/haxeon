struct Child {
  public final text:String;
  public function new(text:String) this.text = text;
}
struct Value {
  public final child:Child;
  public final number:Int;
  public function new(text:String, number:Int) { child = new Child(text); this.number = number; }
}
class Holder {
  public var first:Value;
  public var second:Value;
  public function new() { first = new Value("initial", 1); second = new Value("initial", 1); }
}
function make(number:Int):Value return new Value("managed", number);
function save(holder:Holder, flag:Bool, number:Int):Int {
  var value = make(number);
  if (flag) holder.first = value; else holder.second = value;
  return value.number + value.child.text.length;
}
function capture(flag:Bool):Void->Int {
  var value = make(1), extra = value.number;
  if (flag) return function() return value.number + value.child.text.length + extra;
  return function() return value.number + value.child.text.length + extra;
}
function captureControl(flag:Bool):Void->Int {
  var number = 1, text = "managed", extra = number;
  if (flag) return function() return number + text.length + extra;
  return function() return number + text.length + extra;
}
struct Mutable {
  public var text:String;
  public var number:Int;
  public function new(text:String, number:Int) { this.text = text; this.number = number; }
}
class MutableHolder {
  public var value:Mutable;
  public function new() value = new Mutable("initial", 0);
}
function copyThenEdit(holder:MutableHolder, flag:Bool):Int {
  var value = new Mutable("snapshot", 1);
  if (flag) holder.value = value;
  value.number = 9;
  value.text = "edited";
  return holder.value.number * 10 + value.number;
}
class Events {
  public static var order:Int = 0;
  public static function mark(value:Int):Int { order = order * 10 + value; return value; }
}
function reentrant(depth:Int):Void->Int {
  var value = make(depth), extra = value.number;
  if (depth > 0) return function() return value.number + value.child.text.length + extra + reentrant(depth - 1)();
  return function() return value.number + value.child.text.length + extra;
}
function ordered():Void->Int {
  var value = make(Events.mark(1)), extra = value.number;
  if (Events.mark(2) == 2) return function() return value.number + value.child.text.length + extra;
  return function() return 0;
}
function main():Int {
  var holder = new Holder(), before = hl.Gc.totalAllocated(), total = 0;
  for (i in 0...10000) total += save(holder, (i & 1) == 0, 1);
  if (total != 80000 || hl.Gc.totalAllocated() - before > 4096) return 1;
  if (holder.first.number != 1 || holder.second.child.text != "managed") return 2;
  var saved = holder.first;
  holder.second = saved;
  holder.first = new Value("changed", 7);
  if (saved.child.text != "managed" || holder.second.child.text != "managed") return 3;
  try { save(holder, true, 4); throw "expected"; } catch (error:Dynamic) if (error != "expected") return 4;
  if (holder.first.number != 4 || holder.first.child.text != "managed") return 8;
  before = hl.Gc.totalAllocated(); total = 0;
  for (i in 0...10000) total += capture((i & 1) == 0)();
  var capturedBytes = hl.Gc.totalAllocated() - before;
  before = hl.Gc.totalAllocated();
  for (i in 0...10000) total += captureControl((i & 1) == 0)();
  var controlBytes = hl.Gc.totalAllocated() - before;
  // The inline nested value needs one extra alignment word in this closure environment.
  if (total != 180000 || capturedBytes > controlBytes + 10000 * 8 + 4096) return 5;
  if (reentrant(2)() != 27) return 6;
  var savedClosure:Void->Int = ordered();
  if (Events.order != 12 || savedClosure() != 9) return 7;
  var mutable = new MutableHolder();
  if (copyThenEdit(mutable, true) != 19 || mutable.value.text != "snapshot") return 9;
  if (copyThenEdit(mutable, false) != 19 || mutable.value.text != "snapshot") return 10;
  #if !wasm
  try { copyThenEdit(null, true); return 11; } catch (_:Dynamic) {}
  #end
  return 42;
}
