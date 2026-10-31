struct Value {
  public var x:Int;
  public function new(x:Int) this.x = x;
  public function bump():Void x++;
  public function read():Int return x;
  public function effectRead():Int { Global.calls++; return x; }
  public function forwardRead():Int return Global.observe(this.x + x - 42);
  public function forwardVia():Int return forwardRead();
}

class Global { public static var calls:Int = 0; public static function observe(value:Int):Int { calls++; return value; } }

struct Nested {
  public var value:Value;
  public function new(x:Int) value = new Value(x);
}

class Holder {
  public var nested:Nested;
  public var calls:Int = 0;
  public function new() nested = new Nested(1);
  public function self():Holder {
    calls++;
    return this;
  }
}

function make():Value return new Value(42);

function main():Int {
  if (make().read() != 42) return 1;
  if (make().effectRead() != 42 || Global.calls != 1) return 9;
  if (make().forwardRead() != 42 || Global.calls != 2) return 10;
  if (make().forwardVia() != 42 || Global.calls != 3) return 11;
  var holder = new Holder();
  holder.nested.value.x += 2;
  if (holder.nested.value.x != 3) return 2;
  holder.nested.value.bump();
  if (++holder.nested.value.x != 5) return 3;
  if (holder.nested.value.x++ != 5 || holder.nested.value.x != 6) return 4;
  holder.self().nested.value.x += 3;
  if (holder.calls != 1 || holder.nested.value.x != 9) return 5;
  var values = [new Nested(10), new Nested(20)];
  values[0].value.x += 2;
  values[1].value.bump();
  if (values[0].value.x != 12 || values[1].value.x != 21) return 6;
  var before = new Value(30), after = new Value(40);
  if (haxeon.Structural.assignChanged(holder.self().nested.value, before, after) != 1) return 7;
  if (holder.calls != 2 || holder.nested.value.x != 40 || before.x != 30 || after.x != 40) return 8;
  return 42;
}
