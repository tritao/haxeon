struct Detail {
  public final text:String;
  public function new(text:String) this.text = text;
}
struct Value {
  public final number:Int;
  public final detail:Detail;
  public function new(number:Int) {
    if (number < 0) throw "invalid";
    this.number = increment(number);
    detail = new Detail("managed");
  }
}
class Holder {
  public var current:Null<Value>;
  public var computed(get, never):Value;
  public function new() current = new Value(3);
  function get_computed():Value return new Value(6);
}
function increment(value:Int):Int return value + 1;
function main():Int {
  var holder = new Holder();
  if (holder.current == null) return 1;
  if (holder.computed.number != 7 || holder.current.detail.text != "managed") return 2;
  var make = function():Value return new Value(4);
  var made = make();
  if (made.number != 5 || holder.current.number != 4) return 3;
  try { new Value(-1); return 4; } catch (error:Dynamic) if (error != "invalid") return 5;
  return 42;
}
