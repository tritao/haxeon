interface Reading { function read():Int; }
class Source implements Reading {
 public final value:Int;
 public function new(value:Int) this.value=value;
 public function read():Int return value;
}
struct ResultValue implements Reading {
 public final value:Int;
 public function new(value:Int) this.value=value;
 public function read():Int return value;
}
class CallbackOwner {
 public var callback:Reading->ResultValue;
 public function new(callback:Reading->ResultValue) this.callback=callback;
}
function build(value:Reading):ResultValue return new ResultValue(value.read());
function main():Int {
 var source:Dynamic=new Source(42);
 var reading:Reading=cast source;
 var owner=new CallbackOwner(build);
 var erased:Dynamic=Reflect.field(owner,"callback");
 var restored:Reading->ResultValue=cast erased;
 var result=restored(reading);
 if(!Std.isOfType(result,ResultValue))return 1;
 return result.value;
}
