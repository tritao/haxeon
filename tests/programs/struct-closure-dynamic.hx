struct Point {
  public var x:Int;
  public var y:Int;
  public function new(x:Int, y:Int) { this.x = x; this.y = y; }
}

function addOne(value:Point):Point { value.x += 1; return value; }

function main():Int {
  var closure:Point->Point = addOne;
  var dynamicClosure:Dynamic = closure;
  var restored:Point->Point = cast dynamicClosure;
  var original = new Point(8, 4), result = restored(original);
  return original.x == 8 && result.x == 9 && result.y == 4 ? 42 : 1;
}
