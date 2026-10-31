struct Child {
  public var x:Int;
  public final label:String;
  public function new(x:Int, label:String) { this.x = x; this.label = label; }
  public function observe(callback:Void->Void):Int { callback(); return x * 10 + label.length; }
  public function change(callback:Void->Void):Int { x++; callback(); x++; return x; }
}
struct Outer {
  public var child:Child;
  public var other:Int;
  public function new(x:Int, label:String) { child = new Child(x, label); other = 0; }
}
class Holder {
  public var value:Outer;
  public function new(x:Int) value = new Outer(x, "abc");
}
function main():Int {
  var a = new Holder(1), b = new Holder(5), previous = a.value;
  var result = a.value.child.observe(function() { a.value = new Outer(3, "z"); });
  if (result != 31 || previous.child.x != 1 || previous.child.label != "abc") return 1;
  result = a.value.child.change(function() { a.value = b.value; });
  if (result != 6 || a.value.child.x != 6 || b.value.child.x != 5) return 2;
  var captured:Void->Int = function() return a.value.child.x;
  a.value = b.value;
  if (captured() != 5 || previous.child.x != 1) return 3;
  var callback:Void->Void = function() { a.value = b.value; throw "expected"; };
  try { a.value.child.change(callback); return 4; }
  catch (error:Dynamic) if (error != "expected") return 5;
  if (a.value.child.x != 5 || b.value.child.x != 5) return 6;
  result = a.value.child.change(function() { a.value.child.change(function() {}); });
  if (result != 9 || a.value.child.x != 9) return 7;
  a.value = a.value;
  if (a.value.child.x != 9 || a.value.child.label != "abc") return 8;
  return 42;
}
