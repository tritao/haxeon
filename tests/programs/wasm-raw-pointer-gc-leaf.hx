// The host deliberately passes a managed object's address as an opaque raw pointer.
// Holding that pointer in Dynamic must not keep the object alive in the linear heap.
class PointerGcVictim {
 public var number:Int;
 public function new() number = 123;
}
class PointerGcGarbage {
 public var a:Int; public var b:Int; public var c:Int; public var d:Int;
 public var e:Int; public var f:Int; public var g:Int; public var h:Int;
 public function new() { a=1; b=2; c=3; d=4; e=5; f=6; g=7; h=8; }
}
class PointerGcLeafCensus {
 static var victim:PointerGcVictim;
 static var pointer:Dynamic;
 static var garbage:PointerGcGarbage;
 public static function make():PointerGcVictim { victim = new PointerGcVictim(); return victim; }
 public static function hold(value:hl.Bytes):Void { pointer = value; victim = null; }
 public static function collect():Void { garbage = new PointerGcGarbage(); }
}
function main():Int return 42;
