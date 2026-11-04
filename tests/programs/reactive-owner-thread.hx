import haxeon.reactive.Effect;
import haxeon.reactive.ReactiveRuntime;
import haxeon.reactive.Signal;
import sys.thread.Thread;
#if !wasm
import sys.thread.Lock;
#end

class OwnerModel implements Observable {
 public var count:Int = 0;
 public var unread:Int = 0;
 public function new() {}
}

function main():Int {
 var earlySource = new Signal<Int>(0), earlyError = [""], earlyRuns = [0], workerRuns = [0];
 #if !wasm
 var earlyDone = new Lock();
 #end
 Thread.create(function() {
  try { new Effect(function() { earlyRuns[0]++; earlySource.value; }); } catch (error:Dynamic) earlyError[0] = Std.string(error);
  #if !wasm
  earlyDone.release();
  #end
 });
 #if !wasm
 if (!earlyDone.wait(5.0)) return 9;
 #end
 if (earlyError[0].indexOf("subscribe") < 0 || earlyError[0].indexOf("non-owner thread") < 0) return 8;
 var model = new OwnerModel();
 var signal = new Signal<Int>(0);
 var unobserved = new Signal<String>("zero");
 var observedModel = 0, observedSignal = 0;
 var effect = new Effect(function() { observedModel = model.count; observedSignal = signal.value; });
 var failures = ["", "", ""], workerPassed = [false];
 #if !wasm
 var done = new Lock();
 #end
 Thread.create(function() {
  try model.count = 1 catch (error:Dynamic) failures[0] = Std.string(error);
  try signal.value = 1 catch (error:Dynamic) failures[1] = Std.string(error);
  try { new Effect(function() { workerRuns[0]++; model.count; }); } catch (error:Dynamic) failures[2] = Std.string(error);
  model.unread = 7;
  unobserved.value = "ready";
  workerPassed[0] = model.unread == 7 && unobserved.value == "ready";
  #if !wasm
  done.release();
  #end
 });
 #if !wasm
 if (!done.wait(5.0)) return 10;
 #end
 if (!workerPassed[0] || model.count != 0 || signal.value != 0 || effect.dirty) return 1;
 if (failures[0].indexOf("OwnerModel.count") < 0 || failures[0].indexOf("non-owner thread") < 0) return 2;
 if (failures[1].indexOf("Signal.value") < 0 || failures[1].indexOf("non-owner thread") < 0) return 3;
 if (failures[2].indexOf("subscribe") < 0 || failures[2].indexOf("non-owner thread") < 0) return 4;
 model.count = 2;
 signal.value = 2;
 if (!effect.dirty) return 5;
 ReactiveRuntime.flushEffects();
 if (observedModel != 2 || observedSignal != 2 || effect.dirty) return 6;
 if (earlyRuns[0] != 1 || workerRuns[0] != 1) return 11;
 #if !wasm
 var start = hl.Gc.totalAllocated();
 for (i in 0...10000) { model.unread = i; unobserved.value = i % 2 == 0 ? "even" : "odd"; }
 if (hl.Gc.totalAllocated() != start) return 7;
 #end
 return 42;
}
