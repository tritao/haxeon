class NonNullProbe {
 public var a:Int;
 public var b:Int;
 public function new(a:Int,b:Int) { this.a=a; this.b=b; }
 public function read():Int return a+b;
}
function readAfterGuard(value:NonNullProbe, flag:Bool):Int {
 if (value == null) return 0;
 var sum = value.a;
 if (flag) sum += value.b; else sum += value.a;
 return sum + value.read();
}
function requiredCall(value:NonNullProbe):Int return value.read();
function missing():NonNullProbe { var value:Dynamic=null; return cast value; }
function main():Int {
 var object = new NonNullProbe(10,11);
 if (readAfterGuard(object,true)!=42 || readAfterGuard(missing(),false)!=0) return 1;
 try { requiredCall(missing()); return 2; } catch (error:Dynamic) {}
 return 42;
}
