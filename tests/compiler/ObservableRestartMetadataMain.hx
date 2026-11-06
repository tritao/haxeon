import compiler.Compiler;
import compiler.ir.IrInterpreter;

/** A frontend restart must retain metadata changes discovered before the restart. */
class ObservableRestartMetadataMain {
 static function main():Void {
  for (inlineEnabled in [false, true]) {
   var c = new Compiler();
   c.update("Observable.hx", "interface Observable {}\n");
   c.update("haxeon/reactive/ObservableSource.hx", 'package haxeon.reactive; class ObservableSource { '
    + 'public static var mask:Int = 0; public function new(count:Int) {} '
    + 'public function recordFieldRead(bit:Int):Void mask = mask | (1 << bit); '
    + 'public function hasFieldReaders(bit:Int):Bool return false; public function invalidateField(bit:Int):Void {} }');
   c.update("haxeon/reactive/ReactiveRuntime.hx", 'package haxeon.reactive; class ReactiveRuntime { '
    + 'public static function isTracking():Bool return true; '
    + 'public static function createObservableSource(count:Int):ObservableSource return new ObservableSource(count); '
    + 'public static function recordObservableRead(s:ObservableSource, bit:Int):Void s.recordFieldRead(bit); '
    + 'public static function recordObservableCreation(object:Dynamic):Void {} '
    + 'public static function observableWriteStatus(s:ObservableSource, bit:Int, owner:Dynamic):Int return 0; '
    + 'public static function invalidateObservable(s:ObservableSource, bit:Int):Void {} }');
   c.update("Base.hx", 'class Base implements Observable { public var a:Int; public function new() a = 1; }');
   c.update("Reader.hx", 'class Reader { public static function read(value:Base):Int return value.a; }');
   c.update("Main.hx", 'function main():Int { var b = new Base(); Reader.read(b); return haxeon.reactive.ObservableSource.mask; }');
   c.configure("observable-restart", "test", ["haxeon-inline=" + (inlineEnabled ? "1" : "0")]);
   if (new IrInterpreter(c.compile("Main").ir).run("main") != 1) throw "initial field was not tracked";
   c.update("Base.hx", 'class Base implements Observable { @:unobservable public var a:Int; public function new() a = 1; }');
   var edited = c.compile("Main");
   var result = new IrInterpreter(edited.ir).run("main");
   if (result != 0) throw 'metadata edit kept stale field tracking: $result';
  }
  Sys.println("PASS: frontend restarts preserve incremental metadata changes");
 }
}
