@:structural struct Value {
  public final x:Float;
  public final text:String;
  public function new(x:Float, text:String) { this.x = x; this.text = text; }
}
class Exact {
  public final value:Value;
  public function new(value:Value) this.value = value;
}
class Events {
  public static var order:Int = 0;
  public static var victim:Holder;
  public static function first():Value { order = order * 10 + 1; return victim.value; }
  public static function second():Value { order = order * 10 + 2; victim.exact = new Exact(new Value(9, "managed")); return new Value(4, "managed"); }
  public static function fails():Value { order = order * 10 + 3; throw "expected"; }
  public static function reenter():Value { order = order * 10 + 4; if (!same(new Holder(null), new Holder(null))) throw "reentry"; return new Value(4, "managed"); }
}
class Holder {
  public var exact:Null<Exact>;
  public var value(get, never):Value;
  public function new(exact:Null<Exact>) this.exact = exact;
  function get_value():Value return exact == null ? new Value(4, "managed") : exact.value;
}
function same(a:Holder, b:Holder):Bool return haxeon.Equality.equals(a.value, b.value);
function main():Int {
  var a = new Holder(null), b = new Holder(null);
  var before = hl.Gc.totalAllocated(), total = 0;
  for (i in 0...10000) if (same(a, b)) total++;
  if (total != 10000 || hl.Gc.totalAllocated() - before > 4096) return 1;
  b.exact = new Exact(new Value(4, "managed"));
  if (!same(a, b)) return 2;
  b.exact = new Exact(new Value(5, "managed"));
  if (same(a, b)) return 3;
  b.exact = new Exact(new Value(4, "other"));
  if (same(a, b)) return 4;
  var call:(Holder, Holder)->Bool = same;
  if (call(a, b)) return 5;
  Events.victim = a;
  if (!haxeon.Equality.equals(Events.first(), Events.second()) || Events.order != 12 || a.value.x != 9) return 6;
  Events.order = 0;
  try { haxeon.Equality.equals(Events.first(), Events.fails()); return 7; } catch (error:Dynamic) if (error != "expected" || Events.order != 13) return 8;
  Events.order = 0;
  if (!haxeon.Equality.equals(new Value(4, "managed"), Events.reenter()) || Events.order != 4) return 9;
  if (haxeon.Equality.equals(new Value(Math.NaN, "x"), new Value(Math.NaN, "x"))) return 10;
  if (!haxeon.Equality.equals(new Value(0.0, "x"), new Value(-0.0, "x"))) return 11;
  return 42;
}
