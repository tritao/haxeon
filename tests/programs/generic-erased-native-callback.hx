struct CallbackAnchor { public final id:Int; public function new(id:Int) this.id = id; }
class CallbackHolder<A, B> {
 public var anchor:A;
 public var value:B;
 public var storage:Array<B>;
 public function new(anchor:A, value:B) { this.anchor = anchor; this.value = value; storage = null; }
}
#if wasm
@:hlNative("haxeon_runtime", "nativeCallbackFromIndex") extern function callbackOf(index:Int):hl.Abstract<"native_callback">;
@:hlNative("haxeon_runtime", "nativeCallbackIndex") extern function callbackIndex(value:hl.Abstract<"native_callback">):Int;
#else
@:hlNative("haxeon_runtime", "native_callback_create") extern function createCallback(signature:haxe.io.Bytes, sizes:haxe.io.Bytes, nullable:haxe.io.Bytes, callback:Dynamic):hl.Abstract<"native_callback">;
@:hlNative("haxeon_runtime", "native_callback_close") extern function closeCallback(callback:hl.Abstract<"native_callback">):Bool;
#end
class CallbackCensus {
 static var value:hl.Abstract<"native_callback">;
 public static function prepare(callback:hl.Abstract<"native_callback">):Void value = callback;
 public static function perform(n:Int):Int {
  var count = 0;
  for (_ in 0...n) if (identity(value) == value) count++;
  return count;
 }
 static function identity(callback:hl.Abstract<"native_callback">):hl.Abstract<"native_callback"> return callback;
}
function checkCallback(value:hl.Abstract<"native_callback">):Int {
 var holder = new CallbackHolder<CallbackAnchor,hl.Abstract<"native_callback">>(new CallbackAnchor(1), value);
 var view:CallbackHolder<Dynamic,Dynamic> = holder;
 var rejected = false;
 try view.value = 12 catch (_:Dynamic) rejected = true;
 if (!rejected || holder.value != value) return 1;
 var saved:Dynamic = value;
 var savedAgain:Dynamic = value;
 var number:Dynamic = 123;
 if (saved != savedAgain || (value != null && saved == number)) return 7;
 view.value = saved;
 if (holder.value != value) return 2;
 var restored:hl.Abstract<"native_callback"> = cast view.value;
 if (restored != value) return 3;
 view.value = null;
 if (holder.value != null) return 4;
 return 42;
}
function main():Int {
 if (checkCallback(null) != 42) return 5;
 #if wasm
 var callback = callbackOf(123);
 if (checkCallback(callback) != 42 || callbackIndex(callback) != 123) return 6;
 var bad:Dynamic = 123;
 var castRejected = false;
 try { var invalid:hl.Abstract<"native_callback"> = cast bad; if (invalid != null) return 8; }
 catch (_:Dynamic) castRejected = true;
 if (!castRejected) return 9;
 #else
 var callback = createCallback(haxe.io.Bytes.ofString(">0"), null, null, function() {});
 if (checkCallback(callback) != 42) return 10;
 CallbackCensus.prepare(callback);
 var before = hl.Gc.totalAllocated();
 if (CallbackCensus.perform(8) != 8 || CallbackCensus.perform(1024) != 1024 || hl.Gc.totalAllocated() != before) return 11;
 if (!closeCallback(callback)) return 12;
 #end
 return 42;
}
