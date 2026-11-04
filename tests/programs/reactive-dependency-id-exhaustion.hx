import haxeon.reactive.Effect;
import haxeon.reactive.ObservableSource;
import haxeon.reactive.ReactiveRuntime;
import haxeon.reactive.Signal;

function main():Int {
 var input = new Signal<Int>(0), runs = 0;
 var effect = new Effect(function() { var value = input.value; runs++; });
 var previousId = effect.reactiveId;
 var failure:Dynamic = null;
 try { var impossible = new ObservableSource(0x7fffffff); } catch (error:Dynamic) failure = error;
 if (failure != "Reactive dependency IDs exhausted") return 1;
 var remaining = 0x7fffffff - previousId;
 var last = new ObservableSource(remaining);
 if (last.dependencyId(0) != previousId + 1 || last.dependencyId(remaining - 1) != 0x7fffffff) return 2;
 failure = null;
 try { var impossible = new Signal<Int>(0); } catch (error:Dynamic) failure = error;
 if (failure != "Reactive dependency IDs exhausted") return 3;
 input.value = 1;
 ReactiveRuntime.flushEffects();
 effect.dispose();
 return runs == 2 ? 42 : 4;
}
