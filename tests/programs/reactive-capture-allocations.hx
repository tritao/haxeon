import haxeon.reactive.ObservableSource;
import haxeon.reactive.ReactiveDependencySet;

class ReactiveCaptureCensus {
 static var capture:ReactiveDependencySet;
 static var source:ObservableSource;
 public static function prepare():Void {
  capture = new ReactiveDependencySet(true);
  source = new ObservableSource(2);
  capture.trackField(source, 0);
  capture.trackField(source, 1);
  capture.clearPending();
 }
 public static function perform(n:Int):Int {
  var total = 0;
  for (i in 0...n) {
   capture.trackField(source, 0);
   capture.trackField(source, 1);
   capture.trackField(source, 0);
   total += capture.pendingCount();
   capture.clearPending();
  }
  return total;
 }
}
function main():Int {
 ReactiveCaptureCensus.prepare();
 #if !wasm
 var before = hl.Gc.totalAllocated();
 #end
 var total = ReactiveCaptureCensus.perform(1024);
 #if !wasm
 if (hl.Gc.totalAllocated() != before) return 1;
 #end
 return total == 2048 ? 42 : 2;
}
