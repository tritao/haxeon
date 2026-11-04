import haxeon.reactive.Effect;
import haxeon.reactive.ReactiveRuntime;

class EffectAllocationBase implements Observable {
  public var value:Int = 0;
  public function new() {}
}
class EffectAllocationModel extends EffectAllocationBase {
  public var extra:Int = 1;
  public function new() super();
}
class EffectAllocationNoise implements Observable {
  public var a:Int; public var b:Int; public var c:Int; public var d:Int;
  public var e:Int; public var f:Int; public var g:Int;
  public function new() {}
}
class EffectAllocationCensus {
  static var model:EffectAllocationModel;
  static var effect:Effect;
  static var observed:Int;
  public static function prepare():Void {
    var noise = new EffectAllocationNoise();
    model = new EffectAllocationModel();
    var base:EffectAllocationBase = model;
    effect = new Effect(function() observed = base.value + model.extra + noise.a);
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
  return result == 525824 ? 42 : 1;
}
