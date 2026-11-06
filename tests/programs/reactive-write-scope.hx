import haxeon.reactive.Effect;
import haxeon.reactive.Signal;
import haxeon.reactive.ReactiveRuntime;

class ScopeModel implements Observable {
 public var value:Int = 0;
 @:unobservable public var cache:Int = 0;
 public function new() {}
}
class ScopeChild extends ScopeModel {
 public function new() super();
}
class EqualScopeModel implements Observable {
 public var value:Int = 0;
 public function new() {}
 public function equals(other:EqualScopeModel):Bool return true;
}
class ScopeCreationCensus {
 static var effect:Effect;
 static var runs:Int = 0;
 static var sink:ScopeModel;
 public static function prepare():Void {
  runs = 0;
  effect = new Effect(function() { var fresh = new ScopeModel(); fresh.value = 1; sink = fresh; runs++; });
 }
 public static function perform(n:Int):Int {
  for (_ in 0...n) effect.retrack();
  return runs;
 }
 public static function baseline(n:Int):Void {
  for (_ in 0...n) sink = new ScopeModel();
 }
}

function main():Int {
 var signal = new Signal<Int>(0), old = new ScopeModel();
 var signalRejected = false, oldRejected = false, freshAllowed = false;
 var freshSignalRejected = false, cacheAllowed = false;
 var effect = new Effect(function() {
  try signal.value = 1 catch (_:Dynamic) signalRejected = true;
  var freshSignal = new Signal<Int>(0);
  try freshSignal.value = 1 catch (_:Dynamic) freshSignalRejected = true;
  try old.value = 1 catch (_:Dynamic) oldRejected = true;
  try { old.cache = 3; cacheAllowed = old.cache == 3; } catch (_:Dynamic) {}
  var fresh = new ScopeModel();
  try { fresh.value = 2; freshAllowed = fresh.value == 2; } catch (_:Dynamic) {}
 });
 effect.dispose();
 var failures = (signalRejected ? 0 : 1) + (oldRejected ? 0 : 2) + (freshAllowed ? 0 : 4);
 if (failures != 0) return failures;
 if (!freshSignalRejected || !cacheAllowed) return 7;

 var outerFresh:ScopeModel = null, innerFresh:ScopeModel = null;
 var innerRejectedOuter = false, outerRejectedInner = false, outerStillAllowed = false;
 var nested = new Effect(function() {
  outerFresh = new ScopeModel();
  var inner = new Effect(function() {
   try outerFresh.value = 3 catch (_:Dynamic) innerRejectedOuter = true;
   innerFresh = new ScopeModel();
   innerFresh.value = 4;
  });
  inner.dispose();
  try innerFresh.value = 5 catch (_:Dynamic) outerRejectedInner = true;
  try { outerFresh.value = 6; outerStillAllowed = outerFresh.value == 6; } catch (_:Dynamic) {}
 });
 nested.dispose();
 if (!innerRejectedOuter || !outerRejectedInner || !outerStillAllowed) return 8;

 var previous:ScopeModel = null, rerunRejected = false, runs = 0;
 var repeated = new Effect(function() {
  runs++;
  if (runs == 1) previous = new ScopeModel();
  else try previous.value = 7 catch (_:Dynamic) rerunRejected = true;
 });
 repeated.retrack(); repeated.dispose();
 if (!rerunRejected) return 9;

 var restored = false, untrackedCreationRejected = false;
 var exceptionScope = new Effect(function() {
  var created = new ScopeModel();
  try new Effect(function() throw "nested") catch (_:Dynamic) {}
  try { created.value = 8; restored = created.value == 8; } catch (_:Dynamic) {}
  var untracked:ScopeModel = null;
  ReactiveRuntime.withoutTracking(function() { old.value = 9; untracked = new ScopeModel(); });
  try untracked.value = 1 catch (_:Dynamic) untrackedCreationRejected = true;
 });
 exceptionScope.dispose();
 if (!restored || !untrackedCreationRejected || old.value != 9) return 10;

 var copiedAllowed = false;
 var copyEffect = new Effect(function() {
  var copy:ScopeModel = cast Reflect.copy(old);
  try { Reflect.setField(copy, "value", 11); copiedAllowed = copy.value == 11; } catch (_:Dynamic) {}
 });
 copyEffect.dispose();
 if (!copiedAllowed) return 11;
 var reflectedRejected = false;
 var reflectionEffect = new Effect(function() {
  try Reflect.setField(old, "value", 12) catch (_:Dynamic) reflectedRejected = true;
 });
 reflectionEffect.dispose();
 if (!reflectedRejected) return 12;
 var child = new ScopeChild(), inheritedRejected = false;
 var inheritedEffect = new Effect(function() {
  try Reflect.setField(child, "value", 13) catch (_:Dynamic) inheritedRejected = true;
 });
 inheritedEffect.dispose();
 if (!inheritedRejected) return 13;
 var equalOld = new EqualScopeModel(), identityRejected = false;
 var identityEffect = new Effect(function() {
  var equalFresh = new EqualScopeModel();
  equalFresh.value = 1;
  try equalOld.value = 2 catch (_:Dynamic) identityRejected = true;
 });
 identityEffect.dispose();
 if (!identityRejected) return 14;
 #if !wasm
 ScopeCreationCensus.prepare(); ScopeCreationCensus.baseline(1);
 var before = hl.Gc.totalAllocated();
 ScopeCreationCensus.baseline(1024);
 var baselineBytes = hl.Gc.totalAllocated() - before;
 before = hl.Gc.totalAllocated();
 ScopeCreationCensus.perform(1024);
 if (hl.Gc.totalAllocated() - before != baselineBytes) return 15;
 #end
 return 42;
}
