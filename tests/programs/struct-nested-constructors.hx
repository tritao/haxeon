class Events {
  public static var sequence:Int = 0;
  public static function record(value:Int):Int { sequence = sequence * 10 + value; return value; }
}
struct Inner {
  public final number:Int;
  public final label:String;
  public function new(number:Int, label:String) { this.number = Events.record(number); this.label = label; }
}
struct Middle {
  public final inner:Inner;
  public final second:Int;
  public function new(number:Int, label:String) { inner = new Inner(number, label); second = Events.record(2); }
}
struct Outer {
  public final middle:Middle;
  public final third:Int;
  public function new(number:Int, label:String) { middle = new Middle(number, label); third = Events.record(3); }
}
struct Checked {
  public final inner:Inner;
  public function new(number:Int) {
    if (number < 0) throw "invalid";
    inner = new Inner(number, "kept");
  }
}
class LoopEvents {
  public static var calls:Int = 0;
  public static function step():Void { calls++; if (calls == 4) throw "stop"; }
}
struct RecursiveA {
  public final n:Int;
  public function new() { LoopEvents.step(); new RecursiveB(); n = 1; }
}
struct RecursiveB {
  public final n:Int;
  public function new() { LoopEvents.step(); new RecursiveA(); n = 2; }
}
function make(number:Int):Outer return new Outer(number, "managed");
function read(value:Outer):Int return value.middle.inner.number + value.middle.inner.label.length + value.middle.second + value.third;
function main():Int {
  var before = hl.Gc.totalAllocated(), total = 0;
  for (i in 0...10000) { Events.sequence = 0; total += read(make(1)); }
  if (total != 130000 || Events.sequence != 123 || hl.Gc.totalAllocated() - before > 4096) return 1;
  var saved = make(4);
  if (saved.middle.inner.number != 4 || saved.middle.inner.label != "managed") return 2;
  Events.sequence = 0;
  try { new Checked(-1); return 3; } catch (error:Dynamic) if (error != "invalid") return 4;
  if (Events.sequence != 0) return 5;
  var checked = new Checked(6);
  if (checked.inner.number != 6 || checked.inner.label != "kept" || Events.sequence != 6) return 6;
  try { new RecursiveA(); return 7; } catch (error:Dynamic) if (error != "stop") return 8;
  if (LoopEvents.calls != 4) return 9;
  return 42;
}
