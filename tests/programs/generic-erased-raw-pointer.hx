struct PointerAnchor { public final id:Int; public function new(id:Int) this.id = id; }
class PointerHolder<A,B> {
 public var anchor:A; public var value:B;
 public function new(anchor:A, value:B) { this.anchor = anchor; this.value = value; }
}
#if !wasm
@:hlNative("haxeon_runtime", "__bytes_get_data") extern function pointerData(bytes:haxe.io.Bytes):hl.Bytes;
#end
class PointerOnlyHolder<T> {
 public var value:T;
 public function new(value:T) this.value = value;
}
interface PointerSourceView<T> { function get():T; function put(value:T):Void; }
class PointerSource implements PointerSourceView<hl.Bytes> {
 public var pointer:hl.Bytes;
 public function new(value:hl.Bytes) pointer = value;
 public function get():hl.Bytes return pointer;
 public function put(value:hl.Bytes):Void pointer = value;
}
function pointerIdentity<T>(value:T):T return value;
class PointerBoundaryCensus {
 static var holder:PointerHolder<PointerAnchor,hl.Bytes>;
 static var single:PointerOnlyHolder<hl.Bytes>;
 static var pointer:hl.Bytes;
 public static function prepare(value:hl.Bytes):Int {
  pointer = value;
  holder = new PointerHolder<PointerAnchor,hl.Bytes>(new PointerAnchor(1), value);
  single = new PointerOnlyHolder<hl.Bytes>(value);
  var view:PointerHolder<Dynamic,Dynamic> = holder;
  var saved:Dynamic = value;
  var again:Dynamic = value;
  if (saved != again) return 15;
  var bad:Dynamic = 12;
  if (saved == bad) return 16;
  var singleView:PointerOnlyHolder<Dynamic> = single;
  var singleRejected = false;
  try singleView.value = bad catch (_:Dynamic) singleRejected = true;
  if (!singleRejected || single.value != value) return 17;
  singleView.value = saved;
  var castRejected = false;
  try { var invalid:hl.Bytes = cast bad; if (invalid != null) return 9; } catch (_:Dynamic) castRejected = true;
  if (!castRejected) return 10;
  var absent:Dynamic = null;
  var nullPointer:hl.Bytes = cast absent;
  if (nullPointer != null) return 11;
  var source = new PointerSource(value);
  var sourceView:PointerSourceView<Dynamic> = source;
  var interfaceValue:Dynamic = sourceView.get();
  sourceView.put(interfaceValue);
  if (source.pointer != value) return 12;
  var interfaceRejected = false;
  try sourceView.put(bad) catch (_:Dynamic) interfaceRejected = true;
  if (!interfaceRejected || source.pointer != value) return 13;
  sourceView.put(null);
  if (source.pointer != null) return 14;
  sourceView.put(interfaceValue);
  var rejected = false;
  try view.value = 12 catch (_:Dynamic) rejected = true;
  if (!rejected || holder.value != value) return 1;
  view.value = saved;
  if (holder.value != value) return 2;
  var read:Dynamic = view.value;
  var restored:hl.Bytes = cast read;
  if (restored != value) return 3;
  return 42;
 }
 public static function perform(n:Int):Int {
  var count = 0;
  for (_ in 0...n) if (pointerIdentity(holder.value) == pointer && single.value == pointer) count++;
  return count;
 }
 public static function clear():Int {
  var view:PointerHolder<Dynamic,Dynamic> = holder;
  view.value = null;
  return holder.value == null ? 42 : 4;
 }
}
function main():Int {
 #if !wasm
 var owner = haxe.io.Bytes.alloc(4);
 var value = pointerData(owner);
 if (PointerBoundaryCensus.prepare(value) != 42) return 5;
 var before = hl.Gc.totalAllocated();
 if (PointerBoundaryCensus.perform(8) != 8 || PointerBoundaryCensus.perform(1024) != 1024) return 6;
 if (hl.Gc.totalAllocated() != before) return 7;
 if (PointerBoundaryCensus.clear() != 42) return 8;
 #end
 return 42;
}
