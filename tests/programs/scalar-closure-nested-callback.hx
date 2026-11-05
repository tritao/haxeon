@:hlNative("std", "make_var_args")
extern function makeVarargs(callback:Array<Dynamic>->Dynamic):Dynamic;
class Anchor {
 public var id:Int;
 public function new(id:Int) this.id=id;
}
struct Value {
 public var number:Int;
 public var owner:Anchor;
 public function new(number:Int, owner:Anchor) {this.number=number;this.owner=owner;}
}
typedef Callback = Anchor->Void;
typedef ValueCallback = Value->Value;
class Host {
 public static var observed:Int=0;
 public static function map(value:Value, callback:ValueCallback):Value return callback(value);
 public static function apply(value:Value, callback:Anchor->Void):Int {
  callback(value.owner);
  return value.number;
 }
}
function main():Int {
 var variadic:Dynamic=makeVarargs(args->0);
 if (variadic()!=0) return 1;
 var erased:Dynamic=Host.apply;
 var callback:Anchor->Void=anchor->{Host.observed=anchor.id;};
 var result:Dynamic=erased(new Value(42,new Anchor(17)),callback);
 if (result!=42 || Host.observed!=17) return 2;
 var factory:Void->Callback=cast makeVarargs(args->callback);
 var produced=factory();
 produced(new Anchor(23));
 if (Host.observed!=23) return 3;
 var original=new Value(31,new Anchor(19));
 var valueCallback:ValueCallback=value->new Value(value.number+11,value.owner);
 var erasedMap:Dynamic=Host.map;
 hl.Gc.major();
 var mapped:Value=cast erasedMap(original,valueCallback);
 if (mapped.number!=42 || mapped.owner!=original.owner || original.number!=31) return 4;
 var valueFactory:Void->ValueCallback=cast makeVarargs(args->valueCallback);
 var generated=valueFactory();
 var again=generated(original);
 if (again.number!=42 || again.owner!=original.owner) return 5;
 return 42;
}
