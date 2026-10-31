import haxe.Int64;
struct Color {
  public final red:Float;
  public final green:Float;
  public final blue:Float;
  public final alpha:Float;
  public function new(red:Float, green:Float, blue:Float, alpha:Float) {
    this.red = red; this.green = green; this.blue = blue; this.alpha = alpha;
  }
}
struct Wide {
  public var count:Int;
  public var large:Int64;
  public var flag:Bool;
  public function new(count:Int, large:Int64, flag:Bool) { this.count = count; this.large = large; this.flag = flag; }
}
struct Managed {
  public final text:String;
  public final number:Int;
  public function new(text:String, number:Int) { this.text = text; this.number = number; }
}
struct Fraction {
  public var value:Float32;
  public function new(value:Float) this.value = cast value;
}
struct Narrow {
  public var signed:Int16;
  public var unsigned:UInt8;
  public function new() { signed = 0; unsigned = 0; }
}
class Events {
  public static var calls:Int = 0;
  public static var worker:Worker;
  public static function noop():Void {}
  public static function collect():Void { calls++; hl.Gc.major(); }
  public static function reenter():Void {
    calls++;
    if (calls == 1 && worker.run(new Color(2, 3, 4, 5), noop, false) != 14) throw "reentry";
  }
  public static function fail():Void { calls++; throw "expected"; }
}
class Worker {
  public function new() {}
  public function run(value:Color, callback:Void->Void, shouldThrow:Bool):Float {
    try {
      callback();
      if (shouldThrow) throw "expected";
      return value.red + value.green + value.blue + value.alpha;
    } catch (error:Dynamic) {
      if (error != "expected") throw error;
      return value.red;
    }
  }
  public function first(value:Color, callback:Void->Void):Float {
    try { callback(); return value.red; }
    catch (error:Dynamic) { if (error != "expected") throw error; return value.red; }
  }
  public function wide(value:Wide, callback:Void->Void):Int {
    try { callback(); return value.flag && value.large == Int64.make(1, 5) ? value.count : -1; }
    catch (error:Dynamic) { if (error != "expected") throw error; return value.count; }
  }
  public function managed(value:Managed, callback:Void->Void):Int {
    try { callback(); return value.number + value.text.length; }
    catch (error:Dynamic) { if (error != "expected") throw error; return value.number; }
  }
  public function fraction(value:Fraction, callback:Void->Void):Float {
    try { callback(); return cast value.value; }
    catch (error:Dynamic) { if (error != "expected") throw error; return cast value.value; }
  }
  public function fractionStore(value:Fraction, callback:Void->Void):Float {
    try { value.value = cast 16777217.0; callback(); return cast value.value; }
    catch (error:Dynamic) { if (error != "expected") throw error; return cast value.value; }
  }
  public function narrow(value:Narrow):Int {
    try { value.signed = cast 65535; value.unsigned = cast 257; return (cast value.signed:Int) * 10 + (cast value.unsigned:Int); }
    catch (_:Dynamic) { return 0; }
  }
}
function main():Int {
  var worker = new Worker(), callback:Void->Void = Events.noop;
  var before = hl.Gc.totalAllocated(), total = 0.0;
  for (i in 0...10000) total += worker.run(new Color(1, 2, 3, 4), callback, false);
  if (total != 100000 || hl.Gc.totalAllocated() - before > 4096) return 1;
  before = hl.Gc.totalAllocated(); total = 0;
  for (i in 0...10000) total += worker.managed(new Managed("managed", 1), callback);
  if (total != 80000 || hl.Gc.totalAllocated() - before > 4096) return 2;
  var f:Float32 = cast 1.0000001;
  before = hl.Gc.totalAllocated(); total = 0;
  for (i in 0...10000) total += worker.fraction(new Fraction(cast f), callback);
  if (total != (cast f:Float) * 10000 || hl.Gc.totalAllocated() - before > 4096) return 3;
  if (worker.fractionStore(new Fraction(0), callback) != 16777216.0) return 9;
  if (worker.fractionStore(new Fraction(0), Events.fail) != 16777216.0) return 10;
  var negativeZero = 1.0 / Math.NEGATIVE_INFINITY;
  if (1.0 / worker.first(new Color(negativeZero, 0, 0, 0), callback) != Math.NEGATIVE_INFINITY) return 11;
  var nan = worker.first(new Color(Math.NaN, 0, 0, 0), callback);
  if (nan == nan) return 12;
  var wide = new Wide(7, Int64.make(1, 5), true);
  before = hl.Gc.totalAllocated(); total = 0;
  for (i in 0...10000) total += worker.wide(wide, callback);
  if (total != 70000 || hl.Gc.totalAllocated() - before > 4096) return 13;
  if (worker.wide(wide, Events.fail) != 7) return 14;
  if (worker.narrow(new Narrow()) != -9) return 4;
  Events.worker = worker; Events.calls = 0;
  if (worker.run(new Color(1, 2, 3, 4), Events.reenter, false) != 10 || Events.calls != 1) return 5;
  Events.calls = 0;
  if (worker.run(new Color(1, 2, 3, 4), Events.fail, false) != 1 || Events.calls != 1) return 6;
  if (worker.managed(new Managed("managed", 4), Events.fail) != 4) return 7;
  Events.calls = 0;
  if (worker.managed(new Managed("managed" + Std.string(7), 4), Events.collect) != 12 || Events.calls != 1) return 15;
  if (worker.run(new Color(3, 2, 1, 0), callback, true) != 3) return 8;
  return 42;
}
