import hl.Gc;

private typedef StringBuffer = hl.Abstract<"realtime_string_buffer">;
private class RuntimeWrites {
 @:hlNative("haxeon_runtime", "__string_buffer_new") public static function buffer():StringBuffer return null;
 @:hlNative("haxeon_runtime", "__string_buffer_add") public static function add(b:StringBuffer,s:String):Void {}
 @:hlNative("haxeon_runtime", "__string_buffer_to_string") public static function text(b:StringBuffer):String return null;
 @:hlNative("haxeon_runtime", "__string_split") public static function split(s:String,separator:String):hl.NativeArray<String> return null;
 @:hlNative("haxeon_runtime", "__sys_environment") public static function environment():hl.NativeArray<String> return null;
 @:hlNative("haxeon_runtime", "__sys_args") public static function args():hl.NativeArray<String> return null;
}
class GcRuntimeWriteProbe {
 static var keep:hl.NativeArray<Dynamic>;
 static var parts:hl.NativeArray<String>;
 static var environment:hl.NativeArray<String>;
 static var arguments:hl.NativeArray<String>;
 static var buffer:StringBuffer;
 static function main() {
  Gc.enable(false);
  keep = new hl.NativeArray<Dynamic>(2000000);
  buffer = RuntimeWrites.buffer();
  RuntimeWrites.add(buffer,"before:");
  if (Gc.step(0.001)) throw "expected pending cycle";
  RuntimeWrites.add(buffer,"a,b,c");
  parts = RuntimeWrites.split(RuntimeWrites.text(buffer),",");
  environment = RuntimeWrites.environment();
  arguments = RuntimeWrites.args();
  var done = false;
  for (_ in 0...10000) if (Gc.step(1000.0)) { done = true; break; }
  if (!done || parts.length != 3 || parts[0] != "before:a" || parts[2] != "c") throw "native string references";
  for (i in 0...environment.length) if (environment[i] == null) throw "environment string";
  for (i in 0...arguments.length) if (arguments[i] == null) throw "argument string";
  if (RuntimeWrites.text(buffer) != "before:a,b,c") throw "buffer backing";
  Gc.enable(true);
  Sys.println("PASS: native string factories, buffer growth, split, environment and arguments");
 }
}
