class Owner { public var number:Int; public function new(number:Int) this.number=number; }
struct Packet { public final number:Int; public final owner:Owner; public function new(number:Int,owner:Owner){this.number=number;this.owner=owner;} }
interface Reader { function read():Packet; }
class BaseImpl implements Reader { public var payload:Packet; public function new() payload=new Packet(2,new Owner(40)); public function read():Packet return payload; }
/* IMPLEMENTATIONS */
class Scale {
 public static var reader:Reader;
 public static function prepare(kind:Int):Void { switch kind { case 0: reader=new BaseImpl(); /* RECEIVERS */ default: throw "unknown receiver"; } }
 public static function perform(count:Int):Int { var sum=0;for(_ in 0...count){var value=reader.read();sum+=value.number+value.owner.number;}return sum; }
}
function main():Int {
 Scale.prepare(0);
 if(Scale.perform(8)!=336)return 1;
 #if !wasm
 Scale.perform(100000);
 for(sample in 0...5){var start=Sys.time();var result=Scale.perform(100000);var elapsed=Sys.time()-start;if(result!=4200000)return 2;Sys.println("SAMPLE "+elapsed);}
 for(count in [8,1024]){hl.Gc.censusStart(0);var before=hl.Gc.totalAllocated();var result=Scale.perform(count);var bytes=hl.Gc.totalAllocated()-before;hl.Gc.censusStop();Sys.println("BYTES "+count+" "+bytes);if(result!=42*count)return 3;}
 #end
 return 42;
}
