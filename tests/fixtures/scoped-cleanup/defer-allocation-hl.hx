import hl.Gc;

class DeferAllocationCounter {
 public static var value:Int = 0;
 public static function run(count:Int):Int {
  value = 0;
  var i = 0;
  while (i < count) {
   defer value++;
   i++;
  }
  return value;
 }
}
class ExceptionAllocationCounter {
 public static var failure:Dynamic;
 static function fail():Void { throw failure; }
 public static function baseline(count:Int):Int {
  var i = 0;
  while (i < count) {
   try {
    try fail() catch (_:Dynamic) {}
    fail();
   } catch (_:Dynamic) {}
   i++;
  }
  return i;
 }
 public static function guarded(count:Int):Int {
  var i = 0;
  while (i < count) {
   try {
    defer fail();
    fail();
   } catch (_:Dynamic) {}
   i++;
  }
  return i;
 }
}
class ScopedAllocationResource implements Disposable {
 public function new() {}
 public function dispose():Void { ScopedAllocationCounter.value++; }
}
class ScopedAllocationCounter {
 public static var value:Int = 0;
 public static var resource:ScopedAllocationResource;
 public static function run(count:Int):Int {
  value = 0;
  var i = 0;
  while (i < count) {
   scoped var item:Null<ScopedAllocationResource> = (i % 2 == 0) ? resource : null;
   i++;
  }
  return value;
 }
}
struct ScopedAllocationValue implements Disposable {
 public var amount:Int;
 public function new(amount:Int) { this.amount = amount; }
 public function dispose():Void { ScopedValueCounter.value += amount; }
}
struct MutableScopedAllocationValue implements Disposable {
 public var amount:Int;
 public function new(amount:Int) { this.amount = amount; }
 public function dispose():Void { ScopedMutableCounter.value += amount; amount++; }
}
struct NestedScopedAllocationValue {
 public var amount:Int;
 public function new(amount:Int) { this.amount = amount; }
}
struct CompositeScopedAllocationValue implements Disposable {
 public var inner:NestedScopedAllocationValue;
 public var optional:Null<NestedScopedAllocationValue>;
 public function new() { inner = new NestedScopedAllocationValue(1); optional = new NestedScopedAllocationValue(2); }
 public function dispose():Void { ScopedCompositeCounter.value += inner.amount; if (optional != null) ScopedCompositeCounter.value += optional.amount; }
}
class ScopedCompositeCounter {
 public static var value:Int = 0;
 public static var resource:CompositeScopedAllocationValue;
 public static function run(count:Int):Int {
  value = 0;
  var i = 0;
  while (i < count) {
   scoped var item = resource;
   i++;
  }
  return value;
 }
 public static function baseline(count:Int):Int {
  value = 0;
  var i = 0;
  while (i < count) {
   var item = resource;
   item.dispose();
   i++;
  }
  return value;
 }
}
class ScopedMutableCounter {
 public static var value:Int = 0;
 public static var resource:Null<MutableScopedAllocationValue>;
 public static var directResource:MutableScopedAllocationValue;
 public static function run(count:Int):Int {
  value = 0;
  var i = 0;
  while (i < count) {
   scoped var item = resource;
   i++;
  }
  return value;
 }
 public static function runDirect(count:Int):Int {
  value = 0;
  var i = 0;
  while (i < count) {
   scoped var item = directResource;
   i++;
  }
  return value;
 }
}
class ScopedValueCounter {
 public static var value:Int = 0;
 public static var resource:ScopedAllocationValue;
 public static var nullableResource:Null<ScopedAllocationValue>;
 public static function run(count:Int):Int {
  value = 0;
  var i = 0;
  while (i < count) {
   scoped var item = resource;
   i++;
  }
  return value;
 }
 public static function runNullable(count:Int):Int {
  value = 0;
  var i = 0;
  while (i < count) {
   scoped var item:Null<ScopedAllocationValue> = (i % 2 == 0) ? nullableResource : null;
   i++;
  }
  return value;
 }
}

function main():Int {
 if (DeferAllocationCounter.run(8) != 8) return 1;
 ScopedAllocationCounter.resource = new ScopedAllocationResource();
 if (ScopedAllocationCounter.run(8) != 4) return 3;
 ScopedValueCounter.resource = new ScopedAllocationValue(1);
 ScopedValueCounter.nullableResource = ScopedValueCounter.resource;
 ScopedMutableCounter.resource = new MutableScopedAllocationValue(1);
 ScopedMutableCounter.directResource = new MutableScopedAllocationValue(1);
 ScopedCompositeCounter.resource = new CompositeScopedAllocationValue();
 if (ScopedValueCounter.run(8) != 8) return 4;
 if (ScopedValueCounter.runNullable(8) != 4) return 5;
 if (ScopedMutableCounter.run(8) != 8) return 6;
 if (ScopedMutableCounter.runDirect(8) != 8) return 7;
 if (ScopedCompositeCounter.run(8) != 24) return 10;
 ExceptionAllocationCounter.failure = "failure";
 if (ExceptionAllocationCounter.baseline(8) != 8 || ExceptionAllocationCounter.guarded(8) != 8) return 8;
 var before = Gc.totalAllocated();
 var result = DeferAllocationCounter.run(1024);
 var scopedResult = ScopedAllocationCounter.run(1024);
 var structResult = ScopedValueCounter.run(1024);
 var nullableBefore = Gc.totalAllocated();
 var nullableStructResult = ScopedValueCounter.runNullable(1024);
 var mutableBefore = Gc.totalAllocated();
 var mutableResult = ScopedMutableCounter.run(1024);
 var directMutableResult = ScopedMutableCounter.runDirect(1024);
 var compositeBefore = Gc.totalAllocated();
 var compositeResult = ScopedCompositeCounter.run(1024);
 var after = Gc.totalAllocated();
 if (result != 1024 || scopedResult != 512 || structResult != 1024 || nullableStructResult != 512 || mutableResult != 1024 || directMutableResult != 1024 || compositeResult != 3072 || after != before) {
  ScopedCompositeCounter.baseline(8);
  var baselineBefore = Gc.totalAllocated();
  var baselineComposite = ScopedCompositeCounter.baseline(1024);
  var baselineAfter = Gc.totalAllocated();
  Sys.println('allocation census: defer=$result scoped=$scopedResult value=$structResult nullable=$nullableStructResult mutable=$mutableResult directMutable=$directMutableResult composite=$compositeResult bytes=${after - before} nullableBytes=${mutableBefore - nullableBefore} mutableBytes=${compositeBefore - mutableBefore} compositeBytes=${after - compositeBefore}');
  Sys.println('composite baseline result=$baselineComposite bytes=${baselineAfter - baselineBefore}');
  return 2;
 }
 var baselineStart = Gc.totalAllocated();
 var baselineResult = ExceptionAllocationCounter.baseline(1024);
 var baselineEnd = Gc.totalAllocated();
 var guardedResult = ExceptionAllocationCounter.guarded(1024);
 var guardedEnd = Gc.totalAllocated();
 if (baselineResult != 1024 || guardedResult != 1024 || guardedEnd - baselineEnd != baselineEnd - baselineStart) {
  Sys.println('exception allocation census: baseline=${baselineEnd - baselineStart} guarded=${guardedEnd - baselineEnd}');
  return 9;
 }
 return 42;
}
