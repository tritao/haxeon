class FunctionGlobalOwner {
 public var number:Int;
 public function new(number:Int) this.number=number;
}
class FunctionGlobals {
 public static var read:Void->Int;
 public static var apply:Int->Int;
 public static function prepare():Void {
  var owner=new FunctionGlobalOwner(40);
  read=()->owner.number;
  apply=addTwo;
 }
 static function addTwo(number:Int):Int return number+2;
 public static function perform(count:Int):Int {
  var sum=0;
  for(_ in 0...count)sum+=total();
  return sum;
 }
 public static function total():Int {
  var readValue=read, transform=apply;
  return transform(readValue());
 }
}
function main():Int {
 // A closure-valued data global starts at null, not HashLink's raw function-pointer sentinel.
 if(FunctionGlobals.read!=null || FunctionGlobals.apply!=null)return 1;
 FunctionGlobals.prepare();
 #if !wasm
 hl.Gc.major();
 #end
 if(FunctionGlobals.total()!=42)return 2;
 var saved=FunctionGlobals.read;
 FunctionGlobals.read=null;
 #if !wasm
 hl.Gc.major();
 #end
 if(FunctionGlobals.read!=null || saved()!=40)return 3;
 FunctionGlobals.read=saved;
 for(count in [8,1024]) {
  #if !wasm
  hl.Gc.censusStart(0);
  var before=hl.Gc.totalAllocated();
  #end
  var sum=FunctionGlobals.perform(count);
  #if !wasm
  var allocated=hl.Gc.totalAllocated()-before;
  hl.Gc.censusStop();
  if(allocated!=0)return 4;
  #end
  if(sum!=42*count)return 5;
 }
 return 42;
}
