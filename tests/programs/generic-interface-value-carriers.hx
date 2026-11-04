interface Carrier<T> { function echo(value:T):T; }
interface DerivedIntCarrier extends Carrier<Int> {}
interface PointerSource<T> { function get():T; }
class PointerSourceImpl implements PointerSource<hl.Bytes> {
 final value:hl.Bytes;
 public function new(value:hl.Bytes) { this.value=value; }
 public function get():hl.Bytes return value;
}
struct CarrierValue {
 public final number:Int;
 public final text:String;
 public function new(number:Int, text:String) { this.number=number; this.text=text; }
}
class PointerCarrier implements Carrier<hl.Bytes> {
 public function new() {}
 public function echo(value:hl.Bytes):hl.Bytes return value;
}
class IntCarrier implements Carrier<Int> {
 public function new() {}
 public function echo(value:Int):Int return value;
}
class FloatCarrier implements Carrier<Float> {
 public function new() {}
 public function echo(value:Float):Float return value;
}
struct ValueCarrier implements Carrier<CarrierValue> {
 public final offset:Int;
 public function new() { offset=0; }
 public function echo(value:CarrierValue):CarrierValue return forward(value);
 function forward(value:CarrierValue):CarrierValue return new CarrierValue(value.number+offset, value.text);
}
struct MutatingCarrier implements Carrier<CarrierValue> {
 public var offset:Int;
 public function new() { offset=0; }
 public function echo(value:CarrierValue):CarrierValue {
  offset++;
  return new CarrierValue(value.number+offset, value.text);
 }
}
class GenericCarrier<T> implements Carrier<T> {
 public function new() {}
 public function echo(value:T):T return value;
}
class DerivedIntCarrierImpl implements DerivedIntCarrier {
 public function new() {}
 public function echo(value:Int):Int return value;
}
class CarrierCensus {
 static var pointerCarrier:Carrier<hl.Bytes>;
 static var intCarrier:Carrier<Int>;
 static var floatCarrier:Carrier<Float>;
 static var valueCarrier:Carrier<CarrierValue>;
 static var genericPointer:Carrier<hl.Bytes>;
 static var genericInt:Carrier<Int>;
 static var genericFloat:Carrier<Float>;
 static var genericValue:Carrier<CarrierValue>;
 static var nullableInt:Carrier<Null<Int>>;
 static var derivedInt:DerivedIntCarrier;
 static var mutatingValue:Carrier<CarrierValue>;
 static var boundInt:Int->Int;
 static var boundValue:CarrierValue->CarrierValue;
 static var pointer:hl.Bytes;
 static var source:PointerSource<hl.Bytes>;
 static var payload:CarrierValue;
 public static function prepare(value:hl.Bytes):Void {
  pointerCarrier=new PointerCarrier(); intCarrier=new IntCarrier();
  floatCarrier=new FloatCarrier(); valueCarrier=new ValueCarrier();
  genericPointer=new GenericCarrier<hl.Bytes>(); genericInt=new GenericCarrier<Int>();
  genericFloat=new GenericCarrier<Float>(); genericValue=new GenericCarrier<CarrierValue>();
  nullableInt=new GenericCarrier<Null<Int>>(); derivedInt=new DerivedIntCarrierImpl();
  mutatingValue=new MutatingCarrier();
  source=new PointerSourceImpl(value);
  boundInt=intCarrier.echo; boundValue=valueCarrier.echo;
  var erasedBoundValue:Dynamic=boundValue; boundValue=cast erasedBoundValue;
  pointer=value; payload=new CarrierValue(42, "carrier");
 }
 public static function checkMutation():Bool {
  return mutatingValue.echo(payload).number==43 && mutatingValue.echo(payload).number==44;
 }
 public static function checkNullable():Bool {
  return nullableInt.echo(null)==null && nullableInt.echo(42)==42;
 }
 public static function checkInvalid():Bool {
  var erased:Dynamic=intCarrier, wrong:Carrier<Float>=cast erased;
  try { wrong.echo(42.5); return false; } catch (_:Dynamic) { return true; }
 }
 public static function derivedInts(n:Int):Int {
  var matched=0; for (_ in 0...n) if (derivedInt.echo(42)==42) matched++; return matched;
 }
 public static function pointers(n:Int):Int {
  var matched=0; for (_ in 0...n) if (pointerCarrier.echo(pointer)==pointer) matched++; return matched;
 }
 public static function pointerGetter(n:Int):Int {
  var matched=0; for (_ in 0...n) if (source.get()==pointer) matched++; return matched;
 }
 public static function ints(n:Int):Int {
  var matched=0; for (_ in 0...n) if (intCarrier.echo(42)==42) matched++; return matched;
 }
 public static function floats(n:Int):Int {
  var matched=0; for (_ in 0...n) if (floatCarrier.echo(42.5)==42.5) matched++; return matched;
 }
 public static function values(n:Int):Int {
  var matched=0; for (_ in 0...n) { var value=valueCarrier.echo(payload); if (value.number==42 && value.text=="carrier") matched++; } return matched;
 }
 public static function genericPointers(n:Int):Int {
  var matched=0; for (_ in 0...n) if (genericPointer.echo(pointer)==pointer) matched++; return matched;
 }
 public static function genericInts(n:Int):Int {
  var matched=0; for (_ in 0...n) if (genericInt.echo(42)==42) matched++; return matched;
 }
 public static function genericFloats(n:Int):Int {
  var matched=0; for (_ in 0...n) if (genericFloat.echo(42.5)==42.5) matched++; return matched;
 }
 public static function genericValues(n:Int):Int {
  var matched=0; for (_ in 0...n) { var value=genericValue.echo(payload); if (value.number==42 && value.text=="carrier") matched++; } return matched;
 }
 public static function boundInts(n:Int):Int {
  var callback=boundInt, matched=0; for (_ in 0...n) if (callback(42)==42) matched++; return matched;
 }
 public static function boundValues(n:Int):Int {
  var callback=boundValue, matched=0; for (_ in 0...n) { var value=callback(payload); if (value.number==42 && value.text=="carrier") matched++; } return matched;
 }
}
function main():Int {
 #if !wasm
 CarrierCensus.prepare(null);
 if (!CarrierCensus.checkMutation()) return 10;
 if (!CarrierCensus.checkNullable()) return 14;
 if (!CarrierCensus.checkInvalid()) return 16;
 var before=hl.Gc.totalAllocated();
 if (CarrierCensus.pointers(8)!=8 || CarrierCensus.pointers(1024)!=1024) return 1;
 if (CarrierCensus.pointerGetter(8)!=8 || CarrierCensus.pointerGetter(1024)!=1024) return 13;
 if (CarrierCensus.ints(8)!=8 || CarrierCensus.ints(1024)!=1024) return 2;
 if (CarrierCensus.floats(8)!=8 || CarrierCensus.floats(1024)!=1024) return 3;
 if (CarrierCensus.values(8)!=8 || CarrierCensus.values(1024)!=1024) return 4;
 if (CarrierCensus.genericPointers(8)!=8 || CarrierCensus.genericPointers(1024)!=1024) return 6;
 if (CarrierCensus.genericInts(8)!=8 || CarrierCensus.genericInts(1024)!=1024) return 7;
 if (CarrierCensus.genericFloats(8)!=8 || CarrierCensus.genericFloats(1024)!=1024) return 8;
 if (CarrierCensus.genericValues(8)!=8 || CarrierCensus.genericValues(1024)!=1024) return 9;
 if (CarrierCensus.boundInts(8)!=8 || CarrierCensus.boundInts(1024)!=1024) return 11;
 if (CarrierCensus.boundValues(8)!=8 || CarrierCensus.boundValues(1024)!=1024) return 12;
 if (CarrierCensus.derivedInts(8)!=8 || CarrierCensus.derivedInts(1024)!=1024) return 15;
 if (hl.Gc.totalAllocated()!=before) return 5;
 #end
 return 42;
}
