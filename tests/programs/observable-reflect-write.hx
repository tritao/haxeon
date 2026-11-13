import haxeon.reactive.Effect;

class ReflectedModel implements Observable {
  public var count:Int;
  public var label:String;
  public function new() {
    count = 1;
    label = "a";
  }
}

// Reflection over an observable class: the set-field helper checks the write status and the copy helper records the creation.
// Each is generated after the reachability walk, so the walk must keep what they call.
function main():Int {
  var model = new ReflectedModel();
  Reflect.setField(model, "count", 7);
  if (model.count != 7) return 1;
  var copy:ReflectedModel = cast Reflect.copy(model);
  if (copy.count != 7) return 2;
  var rejected = false;
  var effect = new Effect(function() {
    var read = model.count;
    try
      Reflect.setField(model, "count", 8)
    catch (_:Dynamic)
      rejected = true;
  });
  effect.dispose();
  if (!rejected || model.count != 7) return 3;
  if (Reflect.field(model, "label") != "a") return 4;
  Reflect.setField(model, "label", "b");
  if (model.label != "b") return 5;
  return 42;
}
