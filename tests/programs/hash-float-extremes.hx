import haxeon.Hashing;
import runtime.FloatBits;

struct FloatKey implements Hashable {
  public final value:Float;
  public function new(value:Float) this.value = value;
}

class FloatHashCensus {
  static var sink:Int = 0;
  public static function prepare():Void { perform(1); }
  public static function perform(n:Int):Int {
    var total = 0;
    for (i in 0...n) total ^= Hashing.hash(new FloatKey(i + 0.25));
    sink = total;
    return n;
  }
}

function main():Int {
  var zero = Hashing.hash(new FloatKey(0.0));
  if (zero != Hashing.hash(new FloatKey(-0.0))) return 1;
  var large = Hashing.hash(new FloatKey(1e100));
  var negative = Hashing.hash(new FloatKey(-1e100));
  var positiveInfinity = Hashing.hash(new FloatKey(Math.POSITIVE_INFINITY));
  var negativeInfinity = Hashing.hash(new FloatKey(Math.NEGATIVE_INFINITY));
  var nan = Hashing.hash(new FloatKey(Math.NaN));
  var alternateNaN = FloatBits.fromInt64(haxe.Int64.make(0x7ff80000, 1));
  var negativeNaN = FloatBits.fromInt64(haxe.Int64.make(0xfff80000, 1));
  if (nan != Hashing.hash(new FloatKey(alternateNaN)) || nan != Hashing.hash(new FloatKey(negativeNaN))
    || Hashing.hash(Math.NaN) != Hashing.hash(alternateNaN) || Hashing.hash(Math.NaN) != Hashing.hash(negativeNaN)) return 4;
  if (Hashing.hash(2147483648.25) != 1105723392 || Hashing.hash(-2147483649.0) != -1044381696) return 8;
  if (Hashing.hash(Math.POSITIVE_INFINITY) != 2146435072 || Hashing.hash(Math.NEGATIVE_INFINITY) != -1048576) return 9;
  if (Hashing.hash(0.0) != Hashing.hash(-0.0)) return 5;
  if (large != Hashing.hash(new FloatKey(1e100)) || negative != Hashing.hash(new FloatKey(-1e100))) return 2;
  if (positiveInfinity != Hashing.hash(new FloatKey(Math.POSITIVE_INFINITY))
    || negativeInfinity != Hashing.hash(new FloatKey(Math.NEGATIVE_INFINITY))
    || nan != Hashing.hash(new FloatKey(Math.NaN))) return 3;
  FloatHashCensus.prepare();
  #if !wasm
  var before = hl.Gc.totalAllocated();
  #end
  if (FloatHashCensus.perform(8) != 8 || FloatHashCensus.perform(1024) != 1024) return 6;
  #if !wasm
  if (hl.Gc.totalAllocated() != before) return 7;
  #end
  return 42;
}
