struct SnapshotScalar {
  public final number:Int;
  public function new(number:Int) this.number = number;
  public function doubled():Int return number * 2;
  public function inspect(callback:Void->Void):Int { callback(); return doubled(); }
}
function makeScalar(number:Int):SnapshotScalar return new SnapshotScalar(number);
function noEffect():Void {}
struct SnapshotLabel {
  public final text:String;
  public function new(text:String) this.text = text;
}
struct SnapshotValue {
  public final number:Int;
  public final label:SnapshotLabel;
  public function new(number:Int, text:String) { this.number = number; label = new SnapshotLabel(text); }
  public function doubled():Int return number * 2;
  public function inspect(callback:Void->Void):Int {
    callback();
    return doubled() + label.text.length;
  }
}
class SnapshotBox {
  public var value:SnapshotValue;
  public function new(value:SnapshotValue) this.value = value;
  public function getValue(ignored:Int):SnapshotValue return value;
}
class SnapshotEvents {
  public static var calls:Int = 0;
  public static function sideEffect():Int { calls++; return 0; }
  public static function reenter():Void { calls++; if (calls == 1 && makeValue(3).inspect(function() {}) != 9) throw "reentry"; }
}
function makeValue(number:Int):SnapshotValue return new SnapshotValue(number, "abc");
function copyValue(value:SnapshotValue):SnapshotValue return value;
function absentBox():SnapshotBox return null;
function makeReader(box:SnapshotBox):Void->SnapshotValue return function() return box.value;
function main():Int {
  var callback:Void->Void = noEffect, total = 0;
  var before = hl.Gc.totalAllocated();
  for (i in 0...10000) total += makeScalar(21).inspect(callback);
  if (total != 420000 || hl.Gc.totalAllocated() - before > 4096) return 7;
  var managed = makeValue(5);
  total = 0; before = hl.Gc.totalAllocated();
  for (i in 0...10000) total += copyValue(managed).inspect(callback);
  if (total != 130000 || hl.Gc.totalAllocated() - before > 4096) return 8;
  var box = new SnapshotBox(makeValue(4));
  var temporary = makeValue(5).inspect(function() { box.value = makeValue(9); });
  if (temporary != 13 || box.value.number != 9) return 1;
  var reader:Void->SnapshotValue = makeReader(box);
  var indirect = reader().inspect(function() { box.value = makeValue(6); });
  if (indirect != 21 || box.value.number != 6) return 2;
  var place = box.value.inspect(function() { box.value = makeValue(8); });
  if (place != 19 || box.value.number != 8) return 3;
  if (makeValue(4).inspect(SnapshotEvents.reenter) != 11 || SnapshotEvents.calls != 1) return 4;
  try { makeValue(1).inspect(function() { throw "expected"; }); return 5; }
  catch (error:Dynamic) if (error != "expected") return 6;
  #if !wasm
  SnapshotEvents.calls = 0;
  var caught = false;
  try absentBox().getValue(SnapshotEvents.sideEffect()) catch (_:Dynamic) caught = true;
  if (!caught || SnapshotEvents.calls != 1) return 9;
  #end
  return 42;
}
