struct Rect { public var x:Int; public var y:Int; public function new(x:Int,y:Int) {this.x=x;this.y=y;} }
struct Child { public var text:String; public function new(text:String) this.text=text; }
struct WithOptional {
  public var child:Null<Child>;
  public function new(child:Null<Child>) this.child=child;
  public function update(child:Null<Child>, callback:Void->Void):Void { this.child=child; callback(); }
}
class Holder { public var value:Rect; public function new(value:Rect) this.value=value; }
function build(x:Int):Rect return new Rect(x,2);
function mutate(h:Holder):Int { h.value = new Rect(99, 1); return 1; }
function compare(value:Rect, ignored:Int):Int return value.x;
function main():Int {
  var before=hl.Gc.totalAllocated(), total=0;
  for (i in 0...10000) { var r = i % 2 == 0 ? new Rect(3,2) : build(4); total += r.x + r.y; }
  var allocated=hl.Gc.totalAllocated()-before;
  if (total != 55000 || allocated > 4096) return 1;
  var h = new Holder(new Rect(7, 8)), other = new Holder(new Rect(9, 10));
  if (compare(true ? h.value : other.value, mutate(h)) != 7 || h.value.x != 99) return 2;
  try {
    var result = false ? new Rect(1, 2) : build(4);
    if (result.x != 4) return 3;
    throw "expected";
  } catch (error:Dynamic) { if (error != "expected") return 4; }
  var label = "managed";
  for (i in 0...100) {
    var value = i % 2 == 0 ? new WithOptional(new Child(label)) : new WithOptional(null);
    if (i % 2 == 0) {
      if (value.child == null || value.child.text != label) return 5;
    } else if (value.child != null) return 6;
  }
  var value = new WithOptional(null);
  try { value.update(new Child(label), function() { throw "expected"; }); }
  catch (error:Dynamic) { if (error != "expected") return 7; }
  if (value.child == null || value.child.text != label) return 8;
  return 42;
}
