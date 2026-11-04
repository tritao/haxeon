import haxeon.reactive.Effect;
import haxeon.reactive.ReactiveRuntime;

class EffectAllocationModel implements Observable {
  public var value:Int = 0;
  public function new() {}
}
class EffectAllocationCensus {
  static var model:EffectAllocationModel;
  static var effect:Effect;
  static var observed:Int;
  public static function prepare():Void {
    model = new EffectAllocationModel();
    effect = new Effect(function() observed = model.value);
  }
  public static function perform(n:Int):Int {
    var total = 0;
    for (i in 0...n) {
      model.value = i + 1;
      ReactiveRuntime.flushEffects();
      total += observed;
    }
    return total;
  }
}
function main():Int {
  EffectAllocationCensus.prepare();
  #if !wasm
  var before = hl.Gc.totalAllocated();
  #end
  var result = EffectAllocationCensus.perform(1024);
  #if !wasm
  if (hl.Gc.totalAllocated() != before) return 2;
  #end
  return result == 524800 ? 42 : 1;
}
