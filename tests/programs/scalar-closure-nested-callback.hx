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
class Host {
 public static var observed:Int=0;
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
 return 42;
}
