import haxeon.reactive.Effect;
import haxeon.reactive.ObservableSource;
import haxeon.reactive.ReactiveDependencySet;
import haxeon.reactive.ReactiveRuntime;

class EqualObservable extends ObservableSource implements Equatable {
 public function new(count:Int) super(count);
 public function equals(other:EqualObservable):Bool return true;
}

function main():Int {
 var source=new EqualObservable(1000000), other=new EqualObservable(1);
 if (!(source == other)) return 7;
 var capture=new ReactiveDependencySet(true), nested=new ReactiveDependencySet(true);
 capture.trackField(source,0); capture.trackField(source,1); capture.trackField(source,0);
 if (capture.pendingCount()!=2) return 1;
 var marker=capture.dependencyMarker();
 capture.trackField(source,0); nested.trackField(source,0); capture.trackField(source,0);
 capture.trackField(other,0); capture.trackField(source,999999);
 if (capture.pendingCount()!=5 || nested.pendingCount()!=1) return 2;
 capture.truncatePending(marker);
 capture.trackField(source,0); capture.trackField(source,0);
 if (capture.pendingCount()!=3) return 3;
 capture.clearPending(); capture.trackField(source,1); capture.trackField(source,1);
 if (capture.pendingCount()!=1) return 4;
 var runs=0, secondRuns=0;
 var effect=new Effect(function() { source.recordFieldRead(0); source.recordFieldRead(0); source.recordFieldRead(999999); runs++; });
 var second=new Effect(function() { source.recordFieldRead(0); secondRuns++; });
 source.invalidateField(999999); ReactiveRuntime.flushEffects();
 if (runs!=2 || secondRuns!=1) return 5;
 source.invalidateField(0); ReactiveRuntime.flushEffects();
 if (runs!=3 || secondRuns!=2) return 6;
 effect.dispose(); second.dispose();
 return 42;
}
