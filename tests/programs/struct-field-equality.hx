class Reference {
  public var id:Int;
  public function new(id:Int) this.id = id;
}

enum Payload {
  Entry(value:Int);
}

abstract Modulo(Int) {
  public inline function new(value:Int) this = value;
  @:op(A == B) public static function same(a:Modulo, b:Modulo):Bool return (a : Int) % 10 == (b : Int) % 10;
}

struct AbstractHolder {
  public var value:Modulo;
  public function new(value:Modulo) this.value = value;
}

struct Value {
  public var reference:Reference;
  public var values:Array<Int>;
  public var payload:Payload;
  public var number:Float;
  public function new(reference:Reference, values:Array<Int>, payload:Payload, number:Float) {
    this.reference = reference;
    this.values = values;
    this.payload = payload;
    this.number = number;
  }
}

function main():Int {
  var reference = new Reference(1), values = [1, 2], payload = Entry(3);
  var first = new Value(reference, values, payload, 0.0);
  var same = new Value(reference, values, payload, -0.0);
  if (!(first == same)) return 1;
  var compareCaptured = function():Bool return first == same;
  if (!compareCaptured()) return 6;
  if (first == new Value(new Reference(1), values, payload, 0.0)) return 2;
  if (first == new Value(reference, [1, 2], payload, 0.0)) return 3;
  if (first == new Value(reference, values, Entry(3), 0.0)) return 4;
  var nan = Math.NaN;
  var nanValue = new Value(reference, values, payload, nan);
  if (nanValue == nanValue) return 5;
  if (!(new AbstractHolder(new Modulo(11)) == new AbstractHolder(new Modulo(21)))) return 7;
  if (new AbstractHolder(new Modulo(11)) == new AbstractHolder(new Modulo(22))) return 8;
  return 42;
}
