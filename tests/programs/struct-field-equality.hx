class Reference {
  public var id:Int;
  public function new(id:Int) this.id = id;
  public function equals(other:Reference):Bool return id == other.id;
}

struct Value implements Equatable {
  public var reference:Reference;
  public var optional:Null<Reference>;
  public var number:Float;
  public function new(reference:Reference, optional:Null<Reference>, number:Float) {
    this.reference = reference;
    this.optional = optional;
    this.number = number;
  }
  public function equals(other:Value):Bool
    return reference == other.reference && optional == other.optional && number == other.number;
}

function main():Int {
  var reference = new Reference(1), optional = new Reference(2);
  var first = new Value(reference, optional, 0.0);
  var same = new Value(reference, optional, -0.0);
  if (!(first == same) || !(same == first)) return 1;
  var compareCaptured = function():Bool return first == same;
  if (!compareCaptured()) return 2;
  if (first == new Value(new Reference(1), optional, 0.0)) return 3;
  if (first == new Value(reference, null, 0.0)) return 4;
  var nanValue = new Value(reference, optional, Math.NaN);
  if (nanValue == nanValue) return 5;
  if (new Value(reference, null, 1.0) == new Value(new Reference(1), new Reference(1), 1.0)) return 6;
  return 42;
}
