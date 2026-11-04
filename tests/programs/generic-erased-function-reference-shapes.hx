struct ShapeAnchor { public final x:Int; public function new(x:Int) this.x=x; }
class ShapeHolder<A,B> { public var a:A; public var value:B; public var values:Array<B>; public function new(a:A,value:B) { this.a=a; this.value=value; values=null; } }
function textIdentity(value:String):String return value;
function arrayIdentity(value:Array<Int>):Array<Int> return value;
function textToArray(value:String):Array<Int> return [value.length];
function arrayToText(value:Array<Int>):String return "array";
// These two function types collide under the old 32-bit runtime type hash.
class Cba95abb6358835f5 { public function new() {} }
class Cefe1ade6cf91fbfe { public function new() {} }
function collisionFirst(value:Cba95abb6358835f5):String return "first";
function collisionSecond(value:Cefe1ade6cf91fbfe):String return "second";
class ShapeMethods {
 public function new() {}
 public function text(value:String):String return value;
 public function array(value:Array<Int>):Array<Int> return value;
}
function rejected(holder:ShapeHolder<Dynamic,Dynamic>, value:Dynamic):Bool {
 try { holder.value=value; return false; } catch (_:Dynamic) return true;
}
function main():Int {
 var holder=new ShapeHolder<ShapeAnchor,String->String>(new ShapeAnchor(1),textIdentity);
 var erased:ShapeHolder<Dynamic,Dynamic>=holder;
 if (!rejected(erased,arrayIdentity) || holder.value("kept") != "kept") return 1;
 if (!rejected(erased,textToArray) || !rejected(erased,arrayToText)) return 2;
 var methods=new ShapeMethods();
 if (!rejected(erased,methods.array)) return 3;
 try erased.value=methods.text catch (_:Dynamic) return 7;
 if (holder.value("bound") != "bound") return 4;
 try erased.value=textIdentity catch (_:Dynamic) return 8;
 if (holder.value("static") != "static") return 5;
 var source:Dynamic=textIdentity;
 var arrayView:Array<Int>->Array<Int>=cast source;
 var arrayHolder=new ShapeHolder<ShapeAnchor,Array<Int>->Array<Int>>(new ShapeAnchor(2),arrayIdentity);
 var erasedArray:ShapeHolder<Dynamic,Dynamic>=arrayHolder;
 try erasedArray.value=arrayView catch (_:Dynamic) return 10;
 if (!rejected(erased,arrayView)) return 11;
 var collision=new ShapeHolder<ShapeAnchor,Cba95abb6358835f5->String>(new ShapeAnchor(3),collisionFirst);
 var erasedCollision:ShapeHolder<Dynamic,Dynamic>=collision;
 if (!rejected(erasedCollision,collisionSecond)) return 12;
 if (collision.value(new Cba95abb6358835f5())!="first") return 13;
 try erased.value=null catch (_:Dynamic) return 9;
 if (holder.value != null) return 6;
 return 42;
}
