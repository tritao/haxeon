import compiler.Compiler;
import compiler.ir.IrInterpreter;

/** Observable dependency layouts must follow the runtime class across incremental edits. */
class ObservableLayoutIncrementalMain {
 static function main():Void {
  for (inlineEnabled in [false, true]) {
   var c = new Compiler();
   c.update("Observable.hx", "interface Observable {}\n");
   c.update("haxeon/reactive/ObservableSource.hx", 'package haxeon.reactive; class ObservableSource { '
    + 'public static var mask:Int = 0; public static var lastCount:Int = 0; var count:Int; '
    + 'public function new(count:Int) { this.count = count; lastCount = count; } '
    + 'public function recordFieldRead(bit:Int):Void { if (bit >= count) throw "field bit exceeds reservation"; mask = mask | (1 << bit); } '
    + 'public function hasFieldReaders(bit:Int):Bool return false; public function invalidateField(bit:Int):Void {} }');
   c.update("haxeon/reactive/ReactiveRuntime.hx", 'package haxeon.reactive; class ReactiveRuntime { '
    + 'public static function isTracking():Bool return true; '
    + 'public static function createObservableSource(count:Int):ObservableSource return new ObservableSource(count); '
    + 'public static function recordObservableRead(s:ObservableSource, bit:Int):Void s.recordFieldRead(bit); '
    + 'public static function recordObservableCreation(object:Dynamic):Void {} '
    + 'public static function observableWriteStatus(s:ObservableSource, bit:Int, owner:Dynamic):Int return 0; '
    + 'public static function invalidateObservable(s:ObservableSource, bit:Int):Void {} }');
   c.update("Base.hx", 'class Base implements Observable { public var a:Int; public function new() a = 1; }');
   c.update("Child.hx", 'class Child extends Base { public var b:Int; public function new() { super(); b = 41; } }');
   c.update("Noise.hx", 'class Noise implements Observable { @:unobservable public var sentinel:Int = 0; '
    + 'public var n0:Int; public var n1:Int; public var n2:Int; public var n3:Int; public var n4:Int; public var n5:Int; public var n6:Int; public function new() {} }');
   c.update("Reader.hx", 'class Reader { public static function read(value:Base):Int return value.a; }');
   c.update("Main.hx", 'function main():Int { var n = new Noise(); var c = new Child(); var result = Reader.read(c) + c.b + n.sentinel; '
    + 'return result + haxeon.reactive.ObservableSource.mask * 100 + haxeon.reactive.ObservableSource.lastCount * 10000; }');
   c.configure("observable-layout", "test", ["haxeon-inline=" + (inlineEnabled ? "1" : "0")]);
   if (new IrInterpreter(c.compile("Main").ir).run("main") != 20342) throw "initial layout failed";
   c.update("Child.hx", 'class Child extends Base { public var x:Int; public var y:Int; public var b:Int; '
    + 'public function new() { super(); x = 0; y = 0; b = 41; } }');
   if (new IrInterpreter(c.compile("Main").ir).run("main") != 40942) throw "edited layout failed";
   c.update("Base.hx", 'class Base implements Observable { public var added:Int; public var a:Int; '
    + 'public function new() { a = 1; } }');
   var edited = c.compile("Main");
   var afterBaseEdit = new IrInterpreter(edited.ir).run("main");
   if (afterBaseEdit != 51842) throw 'base edit retained stale field bits: $afterBaseEdit';
  }
  Sys.println("PASS: incremental Observable layouts use the dynamic class");
 }
}
