struct Offset {
  public var x:Int;
  public var y:Int;
  public function new(x:Int, y:Int) { this.x = x; this.y = y; }
  public function move(delta:Int):Void { x += delta; }
  public function moveAndRead():Int { x += 2; return x; }
  public function moveThenThrow():Void { x += 1; throw "moved"; }
  public function tryMove(delta:Int):Int { x += delta; if (delta < 0) throw "negative"; return x; }
  public function trySnapshot(delta:Int):Offset { x += delta; if (delta < 0) throw "negative"; return this; }
  public function around(callback:Void->Void):Void { x += 1; callback(); x += 2; }
  public function drain():Void { if (x > 0) { x -= 1; drain(); } }
}

struct Frame {
  public var offset:Offset;
  public var width:Int;
  public function new(x:Int) { offset = new Offset(x, 7); width = 11; }
}

struct Label {
  public var text:String;
  public var frame:Frame;
  public var opacity:Float32;
  public function new(text:String) { this.text = text; frame = new Frame(4); }
  public function changeText(next:String):String { text = next; return text; }
}

class Panel {
  public var frame:Frame;
  public function new() { frame = new Frame(3); }
}

function shift(value:Offset, delta:Int):Offset {
  value.move(delta);
  return value;
}

function shiftInHandler(value:Offset):Offset {
  try {
    if (value.x == 123) throw "unlikely";
    value.x += 1;
  } catch (error:Dynamic) {
    value.x = -1;
  }
  return value;
}

function adjustLabel(value:Label):Label {
  value.frame.width += value.text.length;
  return value;
}

function countdown(value:Offset):Offset {
  if (value.x == 0) return value;
  value.x -= 1;
  return countdown(value);
}

function genericCopy<T>(value:T):T return value;

function exercise(count:Int):Int {
  var panel = new Panel();
  panel.frame.offset.move(5);
  if (panel.frame.offset.x != 8) return -1;
  if (panel.frame.offset.moveAndRead() != 10 || panel.frame.offset.x != 10) return -1;
  var bound:Void->Int = panel.frame.offset.moveAndRead;
  if (bound() != 12 || panel.frame.offset.x != 12) return -1;
  try {
    panel.frame.offset.moveThenThrow();
  } catch (error:Dynamic) {}
  if (panel.frame.offset.x != 13) return -1;
  panel.frame.offset.around(function() {
    if (panel.frame.offset.x != 14) throw "receiver update was delayed";
    panel.frame.offset.x = 20;
  });
  if (panel.frame.offset.x != 22) return -1;
  var local = new Offset(30, 2);
  var calls = 0;
  local.around(function() { calls += 1; });
  if (local.x != 33 || calls != 1) return -1;
  try { local.around(function() { throw "callback"; }); } catch (error:Dynamic) {}
  if (local.x != 34) return -1;
  local.x = 30;
  try { local.moveThenThrow(); } catch (error:Dynamic) {}
  if (local.x != 31 || local.y != 2) return -1;
  try { local.tryMove(-3); } catch (error:Dynamic) {}
  if (local.x != 28 || local.tryMove(2) != 30 || local.x != 30) return -1;
  try { local.trySnapshot(-2); } catch (error:Dynamic) {}
  var snapshot = local.trySnapshot(1);
  if (local.x != 29 || snapshot.x != 29 || snapshot.y != 2) return -1;
  var other = new Panel();
  other.frame = panel.frame;
  panel.frame = panel.frame;
  panel.frame.offset.x = 12;
  if (other.frame.offset.x != 22 || other.frame.width != 11) return -1;
  var label = new Label("abc"), changed = adjustLabel(label);
  changed.opacity = cast 1.00000003;
  if (label.frame.width != 11 || changed.frame.width != 14 || changed.text != "abc" || changed.opacity != 1.0) return -1;
  if (changed.changeText("xyz") != "xyz" || changed.text != "xyz" || label.text != "abc") return -1;
  var callback:Offset->Offset = shiftInHandler, fromCallback = callback(new Offset(20, 5));
  if (fromCallback.x != 21 || fromCallback.y != 5) return -1;
  var counted = countdown(new Offset(4, 17));
  if (counted.x != 0 || counted.y != 17) return -1;
  var drained = new Offset(3, 19);
  drained.drain();
  if (drained.x != 0 || drained.y != 19) return -1;
  var generic = genericCopy(panel.frame.offset);
  generic.x = 100;
  if (panel.frame.offset.x != 12 || generic.x != 100) return -1;
  var total = 0;
  for (i in 0...count) {
    panel.frame.offset.x = i;
    var copy = panel.frame.offset;
    copy.y = i + 1;
    var shifted = shiftInHandler(shift(copy, 1));
    total += shifted.x + shifted.y + panel.frame.offset.y;
  }
  return total;
}

function main():Int return exercise(3) == 36 ? 42 : 1;
