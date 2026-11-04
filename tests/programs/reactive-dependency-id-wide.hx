import haxeon.reactive.Effect;
import haxeon.reactive.ObservableSource;
import haxeon.reactive.ReactiveDependencySet;
import haxeon.reactive.ReactiveRuntime;
import haxeon.reactive.Signal;

function main():Int {
 var input = new Signal<Int>(0), runs = 0;
 var effect = new Effect(function() { var value = input.value; runs++; });
 var previousId = effect.reactiveId;
 var wide = new ObservableSource(0x7fffffff);
 var wider = new ObservableSource(0x7fffffff);
 var high = new Signal<Int>(0);
 var expected = previousId + haxe.Int64.ofInt(1);
 if (wide.dependencyId(0) != expected) return 1;
 if (wider.dependencyId(0) != expected + haxe.Int64.ofInt(0x7fffffff)) return 2;
 if (high.reactiveId == input.reactiveId || haxe.Int64.toInt(high.reactiveId) != haxe.Int64.toInt(input.reactiveId)) return 3;
 var capture = new ReactiveDependencySet(true);
 capture.track(input); capture.track(high); capture.trackField(wider, 0); capture.track(high);
 if (capture.pendingCount() != 3) return 8;
 var marker = capture.dependencyMarker();
 capture.track(high); capture.track(high);
 if (capture.pendingCount() != 4) return 9;
 capture.truncatePending(marker); capture.track(high);
 if (capture.pendingCount() != 4) return 10;
 var includeFirst = true, collisionRuns = 0;
 var collision = new Effect(function() {
  if (includeFirst) { var a = input.value; }
  var b = high.value;
  collisionRuns++;
 });
 input.value = 1; ReactiveRuntime.flushEffects();
 if (runs != 2 || collisionRuns != 2) return 4;
 includeFirst = false; high.value = 1; ReactiveRuntime.flushEffects();
 if (collisionRuns != 3) return 5;
 high.value = 2; ReactiveRuntime.flushEffects();
 if (collisionRuns != 4) return 6;
 input.value = 2; ReactiveRuntime.flushEffects();
 if (runs != 3 || collisionRuns != 4) return 7;
 collision.dispose(); effect.dispose();
 return 42;
}
