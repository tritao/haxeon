struct Pair {
  public var x:Int;
  public var y:Int;
  public function new(x:Int, y:Int) { this.x = x; this.y = y; }
}
interface Mapper { function map(value:Pair):Pair; }
class Base implements Mapper {
  public function new() {}
  public function map(value:Pair):Pair { value.x += 1; return value; }
}
class Derived extends Base {
  public function new() { super(); }
  override public function map(value:Pair):Pair { value.y += 3; return value; }
}
function main():Int {
  var original = new Pair(8, 4), base:Base = new Derived(), face:Mapper = base;
  var first = base.map(original), second = face.map(original);
  return original.x == 8 && original.y == 4 && first.x == 8 && first.y == 7 && second.x == 8 && second.y == 7 ? 42 : 1;
}
