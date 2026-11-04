import compiler.Frontend;
import compiler.ir.IrInterpreter;

/** The reference interpreter retains the semantic type of an adapted closure. */
class InterpreterClosureCastMain {
 static function main():Void {
  var source = '
struct Anchor { public final x:Int; public function new(x:Int) this.x=x; }
class Holder<A,B> { public var a:A; public var value:B; public var values:Array<B>; public function new(a:A,value:B) { this.a=a; this.value=value; values=null; } }
function text(value:String):String return value;
function array(value:Array<Int>):Array<Int> return value;
function two(value:Int):Int return 2;
function main():Int {
 var original:Dynamic=text;
 var view:Array<Int>->Array<Int>=cast original;
 var holder=new Holder<Anchor,Array<Int>->Array<Int>>(new Anchor(1),array);
 var erased:Holder<Dynamic,Dynamic>=holder;
 try erased.value=view catch (_:Dynamic) return 1;
 var other=new Holder<Anchor,String->String>(new Anchor(2),text);
 var erasedOther:Holder<Dynamic,Dynamic>=other;
 var rejected=false;
 try erasedOther.value=view catch (_:Dynamic) rejected=true;
 if (!rejected || other.value("kept")!="kept") return 2;
 var callRejected=false;
 try view([1]) catch (_:Dynamic) callRejected=true;
 if (!callRejected) return 4;
 var number:Dynamic=two;
 var predicate:Int->Bool=cast number;
 if (!predicate(1)) return 3;
 return 42;
}';
  var result = new IrInterpreter(Frontend.compile(source)).run("main");
  if (result != 42) throw 'interpreter closure cast returned $result';
  Sys.println("PASS: interpreter preserves closure view signatures and conversions");
 }
}
