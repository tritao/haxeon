struct Insets {
  public var left:Int;
  public var top:Int;
  public function new() {}
}

struct Color {
  public var red:Int;
  public var green:Int;
  public function new() {}
}

struct Style {
  public var padding:Insets;
  public var color:Color;
  public function new() {}
}

struct Layout {
  public var style:Style;
  public var offset:Insets;
  public function new() {}
}

struct Small {
  public var byte:UInt8;
  public var signed:Int16;
  public var ratio:Float32;
  public function new() {}
}

struct SmallHolder {
  public var value:Small;
  public function new() {}
}

struct Pair {
  public var first:Insets;
  public var second:Insets;
  public function new() {}
}

struct Constructed {
  public var inner:Insets;
  public function new(n:Int) { inner.left = n; inner.top = n + 1; }
}

class Holder {
  public var value:Constructed;
  public function new() {}
  public function set(n:Int):Void { value = new Constructed(n); }
}

function source():Int return 300;

function copiesAndBranches():Bool {
  var holder = new Holder();
  holder.set(31);
  if (holder.value.inner.left != 31 || holder.value.inner.top != 32) return false;
  var pair = new Pair();
  if (pair.first.left != 0 || pair.second.top != 0) return false;
  pair.first.left = 7;
  pair.first.top = 8;
  pair.second = pair.first;
  pair.first.left = 9;
  if (pair.second.left != 7 || pair.second.top != 8) return false;
  var result = 0;
  for (i in 0...10) {
    var value = new Pair();
    if ((i & 1) == 0) value.first.left = i; else value.first.left = i + 1;
    result += value.first.left;
  }
  if (result != 50) return false;
  var small = new SmallHolder();
  small.value.byte = cast source();
  small.value.signed = cast (source() * 218 + 135);
  small.value.ratio = cast 1.00000003;
  return small.value.byte == 44 && small.value.signed == -1 && small.value.ratio == 1.0;
}

function nestedTotal(count:Int):Int {
  var total = 0;
  for (i in 0...count) {
    var seed = i % 7;
    var layout = new Layout();
    layout.style.padding.left = seed;
    layout.style.color.green = seed + 3;
    layout.offset.top = seed + 5;
    total += layout.style.padding.left + layout.style.color.green + layout.offset.top;
  }
  return total;
}

function main():Int return nestedTotal(1000) == 16991 && copiesAndBranches() ? 42 : 1;
