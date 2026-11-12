struct CanonicalDirection implements Equatable {
  public final x:Float;
  public final y:Float;
  public final z:Float;
  public function new(x:Float, y:Float, z:Float) {
    this.x = x;
    this.y = y;
    this.z = z;
  }
}

struct CanonicalMixed implements Equatable {
  public final number:Int;
  public final label:String;
  public function new(number:Int, label:String) {
    this.number = number;
    this.label = label;
  }
}

enum CanonicalPolicy implements Equatable {
  Fixed;
  Cone(axis:CanonicalDirection, half:Float);
  Mixed(item:CanonicalMixed);
}

function main():Int {
  var value = Cone(new CanonicalDirection(0, 0, 1), 0.1);
  var left:Dynamic = value;
  var right:Dynamic = Cone(new CanonicalDirection(0, 0, 1), 0.1);
  var mixed:Dynamic = Mixed(new CanonicalMixed(7, "value"));
  var mixedAgain:Dynamic = Mixed(new CanonicalMixed(7, "value"));
  return value == Cone(new CanonicalDirection(0, 0, 1), 0.1) && left == right && mixed == mixedAgain ? 42 : 0;
}
