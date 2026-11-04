class ScopedLog {
 public static var value:String = "";
}
class ScopedResource implements Disposable {
 public var name:String;
 public function new(name:String) { this.name = name; }
 public function dispose():Void { ScopedLog.value += name; }
 public function touch():Void { ScopedLog.value += "t"; }
}
class CensusResource implements Disposable {
 public function new() {}
 public function dispose():Void { ScopedCensus.count++; }
}
struct CensusValue implements Disposable {
 public var amount:Int;
 public function new(amount:Int) { this.amount = amount; }
 public function dispose():Void { ScopedCensus.count += amount; }
 public function retain():Void { ScopedCensus.retained = this; }
}
struct MutableCensusValue implements Disposable {
 public var amount:Int;
 public function new(amount:Int) { this.amount = amount; }
 public function dispose():Void { ScopedCensus.count += amount; amount++; }
}
struct RetainingValue implements Disposable {
 public var amount:Int;
 public function new(amount:Int) { this.amount = amount; }
 public function dispose():Void { ScopedCensus.retained = this; }
}
struct NestedCleanupPart {
 public var amount:Int;
 public function new(amount:Int) { this.amount = amount; }
}
struct NestedCleanupValue implements Disposable {
 public var part:NestedCleanupPart;
 public function new(amount:Int) { part = new NestedCleanupPart(amount); }
 public function dispose():Void { ScopedCensus.count += part.amount; }
}
struct CompositeCensusValue implements Disposable {
 public var inner:NestedCleanupPart;
 public var optional:Null<NestedCleanupPart>;
 public function new() { inner = new NestedCleanupPart(1); optional = new NestedCleanupPart(2); }
 public function dispose():Void { ScopedCensus.count += inner.amount; if (optional != null) ScopedCensus.count += optional.amount; }
}
class ThrowingResource implements Disposable {
 public function new() {}
 public function dispose():Void { ScopedLog.value += "d"; throw "dispose"; }
}
class FailureToken {
 public function new() {}
}
enum EnumResource implements Disposable {
 Handle(value:Int);
 public function dispose():Void { ScopedLog.value += "u"; }
}
class ScopedCensus {
 public static var count:Int = 0;
 public static var resource:CensusResource;
 public static var valueResource:CensusValue;
 public static var nullableValueResource:Null<CensusValue>;
 public static var mutableValueResource:MutableCensusValue;
 public static var nullableMutableValueResource:Null<MutableCensusValue>;
 public static var compositeResource:CompositeCensusValue;
 public static var retained:Dynamic;
 public static function prepare():Void { resource = new CensusResource(); valueResource = new CensusValue(1); nullableValueResource = valueResource; mutableValueResource = new MutableCensusValue(1); nullableMutableValueResource = mutableValueResource; }
 public static function prepareComposite():Void { compositeResource = new CompositeCensusValue(); }
 public static function performComposite(n:Int):Int {
  count = 0;
  var i = 0;
  while (i < n) { scoped var item = compositeResource; i++; }
  return count;
 }
 public static function perform(n:Int):Int {
  count = 0;
  var i = 0;
  while (i < n) {
   scoped var item:Null<CensusResource> = (i % 2 == 0) ? resource : null;
   i++;
  }
  return count;
 }
 public static function performValue(n:Int):Int {
  count = 0;
  var i = 0;
  while (i < n) {
   scoped var item = valueResource;
   i++;
  }
  return count;
 }
 public static function performNullableValue(n:Int):Int {
  count = 0;
  var i = 0;
  while (i < n) {
   scoped var item:Null<CensusValue> = (i % 2 == 0) ? nullableValueResource : null;
   i++;
  }
  return count;
 }
 public static function performMutableValue(n:Int):Int {
  count = 0;
  var i = 0;
  while (i < n) {
   scoped var item = mutableValueResource;
   i++;
  }
  return count;
 }
 public static function performNullableMutableValue(n:Int):Int {
  count = 0;
  var i = 0;
  while (i < n) {
   scoped var item:Null<MutableCensusValue> = (i % 2 == 0) ? nullableMutableValueResource : null;
   i++;
  }
  return count;
 }
}
function helper(value:ScopedResource):Void { value.touch(); }
function normal():Int {
 scoped var first = new ScopedResource("a");
 scoped var second:Null<ScopedResource> = new ScopedResource("b");
 scoped var missing:Null<ScopedResource> = null;
 helper(first);
 return 42;
}
function exceptional():Void {
 scoped var resource = new ScopedResource("e");
 throw "failure";
}
function failedInitializer():ScopedResource { throw "init"; }
function initializationFailure():Void {
 scoped var first = new ScopedResource("i");
 scoped var second = failedInitializer();
}
function disposalFailure():Void {
 scoped var first = new ScopedResource("f");
 scoped var second = new ThrowingResource();
 throw "original";
}
function genericCleanup<T:Disposable>(value:T):Void {
 scoped var resource = value;
}
function interfaceHelper(value:Disposable):Void { value.dispose(); }
function nullableInterfaceHelper(value:Null<Disposable>):Void { if (value != null) value.dispose(); }
function scopedEnumToInterface():Void {
 scoped var resource = Handle(8);
 interfaceHelper(resource);
}
function nullableEnum():Void {
 scoped var absent:Null<EnumResource> = null;
 scoped var present:Null<EnumResource> = Handle(9);
 nullableInterfaceHelper(absent);
 nullableInterfaceHelper(present);
}
function repeatedValueCalls():Int {
 ScopedCensus.count = 0;
 var value = new CensusValue(2);
 value.dispose();
 value.amount = 5;
 value.dispose();
 return ScopedCensus.count;
}
function retainedValueCall():Int {
 var value = new CensusValue(3);
 value.dispose();
 value.retain();
 value.amount = 9;
 var saved:CensusValue = cast ScopedCensus.retained;
 return saved.amount;
}
function ordinaryMutableCall():Int {
 var value = new MutableCensusValue(3);
 value.dispose();
 value.dispose();
 return value.amount;
}
function scopedMutableCall():Int {
 ScopedCensus.count = 0;
 {
  scoped var value = new MutableCensusValue(1);
  defer value.amount = 7;
 }
 return ScopedCensus.count;
}
function scopedRetainingCall():Int {
 {
  scoped var value = new RetainingValue(11);
 }
 var saved:RetainingValue = cast ScopedCensus.retained;
 return saved.amount;
}
function nestedMutationAndThrow():Int {
 ScopedCensus.count = 0;
 try {
  scoped var value = new NestedCleanupValue(1);
  value.part.amount = 4;
  defer value.part.amount = 7;
  throw "nested";
 } catch (error:Dynamic) {
  if (error != "nested") return -1;
 }
 return ScopedCensus.count;
}
function objectFailure(original:FailureToken):Void {
 scoped var resource = new ThrowingResource();
 throw original;
}
function main():Int {
 if (normal() != 42 || ScopedLog.value != "tba") return 1;
 var caught:Dynamic = null;
 try exceptional() catch (error:Dynamic) caught = error;
 if (caught != "failure" || ScopedLog.value != "tbae") return 2;
 caught = null;
 try initializationFailure() catch (error:Dynamic) caught = error;
 if (caught != "init" || ScopedLog.value != "tbaei") return 3;
 caught = null;
 try disposalFailure() catch (error:Dynamic) caught = error;
 if (caught != "original" || ScopedLog.value != "tbaeidf") return 4;
 genericCleanup(Handle(7));
 if (ScopedLog.value != "tbaeidfu") return 5;
 scopedEnumToInterface();
 if (ScopedLog.value != "tbaeidfuuu") return 8;
 nullableEnum();
 if (ScopedLog.value != "tbaeidfuuuuu") return 9;
 if (repeatedValueCalls() != 7) return 6;
 if (retainedValueCall() != 3) return 7;
 if (ordinaryMutableCall() != 5) return 10;
 if (scopedMutableCall() != 7) return 11;
 if (scopedRetainingCall() != 11) return 12;
 var original = new FailureToken();
 caught = null;
 try objectFailure(original) catch (error:Dynamic) caught = error;
 if (caught != original) return 13;
 if (nestedMutationAndThrow() != 7) return 14;
 return 42;
}
