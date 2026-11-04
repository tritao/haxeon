/** Typed closure calls and matching Dynamic casts must not allocate per call. */
class ClosureSignatureReceiver {
 public function new() {}
 public function text(value:String):String return value;
}
function closureSignatureText(value:String):String return value;
class ClosureSignatureCensus {
 static var staticFunction:String->String;
 static var boundFunction:String->String;
 static var staticDynamic:Dynamic;
 static var boundDynamic:Dynamic;
 public static function prepare():Void {
  staticFunction=closureSignatureText;
  boundFunction=new ClosureSignatureReceiver().text;
  staticDynamic=staticFunction;
  boundDynamic=boundFunction;
  // Materialize the string literal before measuring calls on targets with lazy strings.
  if (perform(1)!=1) throw "closure warmup failed";
 }
 public static function perform(n:Int):Int {
  for (_ in 0...n) {
   var staticView:String->String=cast staticDynamic;
   var boundView:String->String=cast boundDynamic;
   if (staticView!=staticFunction || boundView!=boundFunction) return -1;
   if (staticView("value")!="value" || boundView("value")!="value") return -2;
  }
  return n;
 }
}
function main():Int {
 ClosureSignatureCensus.prepare();
 #if !wasm
 var before=hl.Gc.totalAllocated();
 #end
 if (ClosureSignatureCensus.perform(8)!=8 || ClosureSignatureCensus.perform(1024)!=1024) return 1;
 #if !wasm
 if (hl.Gc.totalAllocated()!=before) return 2;
 #end
 return 42;
}
