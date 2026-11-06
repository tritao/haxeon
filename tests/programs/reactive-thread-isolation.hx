import haxeon.reactive.ObservableSource;
import haxeon.reactive.ReactiveDependencySet;
import haxeon.reactive.ReactiveRuntime;
import sys.thread.Thread;
#if !wasm
import sys.thread.Lock;
#end

class ThreadScopeModel implements Observable {
 public var value:Int = 0;
 public function new() {}
}

#if wasm
@:access(sys.thread.Tls)
@:access(haxeon.reactive.ReactiveRuntime)
class TlsProbe {
 public static function count(value:sys.thread.Tls<ObservableSource>):Int return value.threads.length;
 public static function creationCount():Int return ReactiveRuntime.creationLogs.threads.length;
}
#end

function fail(message:String):Int { throw message; }

function main():Int {
 var mainCollector = new ReactiveDependencySet(true);
 var workerCollector = new ReactiveDependencySet(true);
 var mainSource = new ObservableSource(3);
 var workerSource = new ObservableSource(3);
 var workerStartedTracked = [false];
 var mainFresh:ThreadScopeModel = null, workerRejectedMain = [false], workerFreshAllowed = [false];
 #if !wasm
 var ready = new Lock(), done = new Lock();
 Thread.create(function() {
  ready.wait();
  workerStartedTracked[0] = ReactiveRuntime.isTracking();
  workerSource.recordFieldRead(2);
  ReactiveRuntime.withTracking(workerCollector, function() {
   workerSource.recordFieldRead(1);
   var fresh = new ThreadScopeModel(); fresh.value = 2; workerFreshAllowed[0] = true;
   try mainFresh.value = 3 catch (_:Dynamic) workerRejectedMain[0] = true;
   return 0;
  });
  done.release();
 });
 #end
 ReactiveRuntime.withTracking(mainCollector, function() {
  mainFresh = new ThreadScopeModel();
  mainSource.recordFieldRead(0);
  #if !wasm
  hl.Gc.major();
  #end
  #if wasm
  Thread.create(function() {
   workerStartedTracked[0] = ReactiveRuntime.isTracking();
   workerSource.recordFieldRead(2);
   ReactiveRuntime.withTracking(workerCollector, function() {
    workerSource.recordFieldRead(1);
    var fresh = new ThreadScopeModel(); fresh.value = 2; workerFreshAllowed[0] = true;
    try mainFresh.value = 3 catch (_:Dynamic) workerRejectedMain[0] = true;
    return 0;
   });
  });
  #else
  ready.release();
  done.wait();
  #end
  mainFresh.value = 4;
  mainSource.recordFieldRead(2);
  return 0;
 });
 if (workerStartedTracked[0] || ReactiveRuntime.isTracking()) return 1;
 if (!workerFreshAllowed[0] || !workerRejectedMain[0] || mainFresh.value != 4) return 7;
 if (mainCollector.pendingCount() != 2 || mainCollector.pendingSourceAt(0) != mainSource
  || mainCollector.pendingFieldBitAt(0) != 0 || mainCollector.pendingSourceAt(1) != mainSource
  || mainCollector.pendingFieldBitAt(1) != 2) return 2;
 if (workerCollector.pendingCount() != 1 || workerCollector.pendingSourceAt(0) != workerSource
  || workerCollector.pendingFieldBitAt(0) != 1) return 3;
 var restored = [false, false];
 ReactiveRuntime.withTracking(mainCollector, function() {
  try ReactiveRuntime.withTracking(workerCollector, function() return fail("nested")) catch (_:Dynamic) {}
  restored[0] = ReactiveRuntime.isTracking();
  try ReactiveRuntime.withoutTracking(function() { if (ReactiveRuntime.isTracking()) throw "tracked"; return fail("untracked"); })
  catch (_:Dynamic) {}
  restored[1] = ReactiveRuntime.isTracking();
  return 0;
 });
 if (!restored[0] || !restored[1] || ReactiveRuntime.isTracking()) return 4;
 #if !wasm
 var action = function():String return "tracked";
 ReactiveRuntime.withTracking(mainCollector, action);
 var before = hl.Gc.totalAllocated();
 for (_ in 0...10000) ReactiveRuntime.withTracking(mainCollector, action);
 if (hl.Gc.totalAllocated() != before) return 6;
 #end
 #if wasm
 var local = new sys.thread.Tls<ObservableSource>();
 local.value = mainSource;
 for (_ in 0...1000) Thread.create(function() { local.value = workerSource; local.value = null; });
 if (TlsProbe.count(local) != 1 || local.value != mainSource) return 5;
 for (_ in 0...1000) Thread.create(function() {
  ReactiveRuntime.withTracking(workerCollector, function() { var fresh = new ThreadScopeModel(); fresh.value = 1; return 0; });
 });
 if (TlsProbe.creationCount() != 1) return 8;
 #end
 return 42;
}
