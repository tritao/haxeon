class InterfaceValueOwner {
 public var number:Int;
 public function new(number:Int) this.number=number;
}
struct InterfaceValue {
 public var number:Int;
 public var owner:InterfaceValueOwner;
 public function new(number:Int,owner:InterfaceValueOwner) {
  this.number=number; this.owner=owner;
 }
}
interface ValueReader {
 function read():InterfaceValue;
 function echo(value:InterfaceValue):InterfaceValue;
 function replace(value:InterfaceValue):Void;
 function fail(value:InterfaceValue):InterfaceValue;
 function optional(value:InterfaceValue,present:Bool):Null<InterfaceValue>;
}
interface InheritedValueReader extends ValueReader {}
class ValueReaderImpl implements InheritedValueReader {
 var value:InterfaceValue;
 public function new(value:InterfaceValue) this.value=value;
 public function read():InterfaceValue return value;
 public function echo(value:InterfaceValue):InterfaceValue return value;
 public function replace(value:InterfaceValue):Void this.value=value;
 public function fail(value:InterfaceValue):InterfaceValue throw "expected interface failure";
 public function optional(value:InterfaceValue,present:Bool):Null<InterfaceValue> return present?value:null;
}
class InterfaceValueCensus {
 public static var reader:ValueReader;
 public static var inherited:InheritedValueReader;
 public static var readBound:Void->InterfaceValue;
 public static var echoBound:InterfaceValue->InterfaceValue;
 public static var optionalBound:(InterfaceValue,Bool)->Null<InterfaceValue>;
 public static function prepare():Void {
  var implementation=new ValueReaderImpl(new InterfaceValue(2,new InterfaceValueOwner(40)));
  reader=implementation; inherited=implementation;
  readBound=reader.read; echoBound=inherited.echo; optionalBound=reader.optional;
 }
 public static function perform(count:Int):Int {
  var sum=0;
  for(_ in 0...count) {
   var first=reader.echo(reader.read());
   var read=readBound, echo=echoBound;
   var second=echo(read());
   var third=inherited.read();
   if(first.number+first.owner.number!=42 || second.number+second.owner.number!=42)return -1;
   var optional=reader.optional(first,true);
   if(optional==null || optional.number!=2 || optional.owner!=first.owner)return -2;
   if(reader.optional(first,false)!=null)return -3;
   sum+=third.number+third.owner.number;
  }
  return sum;
 }
}
function main():Int {
 InterfaceValueCensus.prepare();
 var reader=InterfaceValueCensus.reader;
 var saved=reader.read();
 reader.replace(new InterfaceValue(99,saved.owner));
 if(saved.number!=2 || saved.owner.number!=40 || reader.read().number!=99)return 1;
 reader.replace(saved);
 var caught=false;
 try reader.fail(saved) catch(error:Dynamic) caught=true;
 if(!caught)return 2;
 // Nullable closure results still use their logical result ABI; exercise correctness outside the component-call census.
 var optionalFn=InterfaceValueCensus.optionalBound,optional=optionalFn(saved,true);
 if(optional==null || optional.number!=saved.number || optional.owner!=saved.owner || optionalFn(saved,false)!=null)return 5;
 #if !wasm
 hl.Gc.major();
 #end
 for(count in [8,1024]) {
  #if !wasm
  hl.Gc.censusStart(0);
  var before=hl.Gc.totalAllocated();
  #end
  var result=InterfaceValueCensus.perform(count);
  #if !wasm
  var allocated=hl.Gc.totalAllocated()-before;
  hl.Gc.censusStop();
  if(allocated!=0)return 3;
  #end
  if(result!=42*count)return 4;
 }
 return 42;
}
