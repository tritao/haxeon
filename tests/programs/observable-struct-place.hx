import haxeon.reactive.Effect;
import haxeon.reactive.ReactiveRuntime;

struct ObservablePoint implements Equatable {
  public var x:Int;
  public function new(x:Int) this.x = x;
  public function move():Void x++;
}
class ObservablePointBase implements Observable {
  public var pos:ObservablePoint;
  @:unobservable public var cache:ObservablePoint;
  public function new() { pos = new ObservablePoint(1); cache = new ObservablePoint(3); }
}
class ObservablePointModel extends ObservablePointBase {
  public function new() super();
}
class ObservablePlaceAnchor {
  public final value:Int;
  public function new(value:Int) this.value = value;
}
struct ObservablePlaceValue implements Equatable {
  public var number:Int;
  public var anchor:ObservablePlaceAnchor;
  public function new(number:Int, anchor:ObservablePlaceAnchor) { this.number = number; this.anchor = anchor; }
  public function equals(other:ObservablePlaceValue):Bool return number == other.number && anchor == other.anchor;
}
class ObservablePlaceModel implements Observable {
  public var value:ObservablePlaceValue;
  public function new(anchor:ObservablePlaceAnchor) value = new ObservablePlaceValue(0, anchor);
}
class ObservablePlaceCensus {
  static var model:ObservablePlaceModel;
  static var effect:Effect;
  static var observed:Int;
  public static function prepare():Void {
    model = new ObservablePlaceModel(new ObservablePlaceAnchor(7));
    effect = new Effect(function() observed = model.value.number);
  }
  public static function perform(n:Int):Int {
    var total = 0;
    for (i in 0...n) {
      var copy = model.value;
      copy.number = i;
      model.value = copy;
      ReactiveRuntime.flushEffects();
      total += observed;
    }
    return total;
  }
}
function makeObservablePoint():ObservablePoint return new ObservablePoint(1);
function main():Int {
  var model = new ObservablePointModel(), runs = 0, last = 0;
  var effect = new Effect(function() { last = model.pos.x; runs++; });
  var point = model.pos;
  point.x = 2;
  model.pos = point;
  if (!effect.dirty) return 1;
  ReactiveRuntime.flushEffects();
  if (last != 2 || runs != 2) return 2;
  model.cache.x = 4;
  model.cache.move();
  var updateCache = model.cache.move;
  updateCache();
  var updateTemporary = makeObservablePoint().move;
  updateTemporary();
  if (model.cache.x != 6 || effect.dirty) return 3;
  effect.dispose();
  ObservablePlaceCensus.prepare();
  #if !wasm
  var before = hl.Gc.totalAllocated();
  #end
  var total = ObservablePlaceCensus.perform(1024);
  #if !wasm
  if (hl.Gc.totalAllocated() != before) return 4;
  #end
  return total == 523776 ? 42 : 5;
}
