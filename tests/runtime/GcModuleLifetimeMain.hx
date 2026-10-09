import compiler.Compiler;
import compiler.hl.HlWriter;
import runtime.Runtime;
import hl.Gc;

private extern class BoundaryGc {
 @:hlNative("std", "gc_step") static function step(budget:Float):Bool;
 @:hlNative("std", "gc_incremental_pending") static function pending():Bool;
}
class GcModuleLifetimeMain {
 static var ballast:hl.NativeArray<Dynamic>;
 static function finish() {
  for (_ in 0...10000) if (BoundaryGc.step(1000.0)) return;
  throw "module collection did not complete";
 }
 static function generation(bytes:haxe.io.Bytes, identity:haxe.io.Bytes, make:Int) {
  if (BoundaryGc.step(0.001) || !BoundaryGc.pending()) throw "expected pending module load";
  var loaded = Runtime.load(bytes,identity);
  var retained = Runtime.retainClosure(loaded,make);
  if (Runtime.callRetainedClosureInt(retained) != 42) throw "new module capture";
  finish();
  if (Runtime.callRetainedClosureInt(retained) != 42) throw "capture lost after tracing";
  if (BoundaryGc.step(0.001) || !BoundaryGc.pending()) throw "expected pending module dispose";
  Runtime.dispose(loaded);
  if (Runtime.callRetainedClosureInt(retained) != 42) throw "disposed module capture";
  finish();
  if (Runtime.callRetainedClosureInt(retained) != 42) throw "retired module capture lost";
  retained.release();
  Runtime.dispose(loaded);
 }
 static function main() {
  var compiler = new Compiler();
  compiler.update("Main.hx", "function make():() -> Int { var values = [40, 2]; return function() return values[0] + values[1]; } function main():Int { return 42; }");
  var compiled = compiler.compile("Main");
  var bytes = HlWriter.encode(compiled.module);
  Gc.enable(false);
  ballast = new hl.NativeArray<Dynamic>(2000000);
  for (i in 0...12) {
   generation(bytes,compiled.runtimeIdentity,compiled.functionIds.get("Main.make"));
   Gc.major();
   if (Runtime.retryRetirements() != 0) throw 'module retirement blocked after generation $i';
  }
  ballast = null;
  Gc.enable(true);
  Sys.println("PASS: module load/dispose during pending GC, retained captures and retirement");
 }
}
