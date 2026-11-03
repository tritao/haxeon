struct ShapeAnchor { public final x:Int; public function new(x:Int) this.x=x; }
class ShapeHolder<A,B> { public var a:A; public var value:B; public var values:Array<B>; public function new(a:A,value:B) { this.a=a; this.value=value; values=null; } }
function textIdentity(value:String):String return value;
function arrayIdentity(value:Array<Int>):Array<Int> return value;
function main():Int {
 var holder=new ShapeHolder<ShapeAnchor,String->String>(new ShapeAnchor(1),textIdentity);
 var erased:ShapeHolder<Dynamic,Dynamic>=holder;
 var rejected=false;
 try erased.value=arrayIdentity catch (_:Dynamic) rejected=true;
 return rejected ? 42 : 43;
}
