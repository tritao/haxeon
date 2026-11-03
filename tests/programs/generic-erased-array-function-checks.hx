struct BoundaryAnchor { public final id:Int; public function new(id:Int) this.id = id; }
struct BoundaryElement { public var number:Int; public var text:String; public function new(number:Int, text:String) { this.number = number; this.text = text; } }
struct OtherBoundaryElement { public var number:Int; public function new(number:Int) this.number = number; }
class BoundaryObject { public var number:Int; public function new(number:Int) this.number = number; }
class BoundaryCalculator { public function new() {} public function increment(value:Int):Int return value + 1; }
class BoundaryContainer<A,B> {
 public var anchor:A; public var value:B; public var storage:Array<B>;
 public function new(anchor:A, value:B) { this.anchor = anchor; this.value = value; storage = null; }
}
function increment(value:Int):Int return value + 1;
function twoArgs(a:Int,b:Int):Int return a + b;
function floatIdentity(value:Float):Float return value;
function elementIdentity(value:BoundaryElement):BoundaryElement return value;
function otherElementIdentity(value:OtherBoundaryElement):OtherBoundaryElement return value;
class BoundaryClosureCensus {
 static var holder:BoundaryContainer<BoundaryAnchor,OtherBoundaryElement->OtherBoundaryElement>;
 public static function prepare():Void {
  holder = new BoundaryContainer<BoundaryAnchor,OtherBoundaryElement->OtherBoundaryElement>(new BoundaryAnchor(1), otherElementIdentity);
  var erased:BoundaryContainer<Dynamic,Dynamic> = holder;
  erased.value = otherElementIdentity;
 }
 public static function perform(n:Int):Int {
  var sum = 0;
  for (_ in 0...n) sum += holder.value(new OtherBoundaryElement(1)).number;
  return sum;
 }
}
function main():Int {
 var ints = new BoundaryContainer<BoundaryAnchor,Array<Int>>(new BoundaryAnchor(1), [3,4]);
 var intView:BoundaryContainer<Dynamic,Dynamic> = ints;
 var rejected = false;
 try intView.value = "wrong" catch (_:Dynamic) rejected = true;
 if (!rejected || ints.value[0] != 3) return 1;
 rejected = false;
 try intView.value = [1.5,2.5] catch (_:Dynamic) rejected = true;
 if (!rejected || ints.value[1] != 4) return 2;
 var replacement:Array<Int> = [8,9]; intView.value = replacement;
 if (ints.value != replacement || ints.value[0] != 8) return 3;
 intView.value = null; if (ints.value != null) return 4;
 var optional = new BoundaryContainer<BoundaryAnchor,Null<Array<Int>>>(new BoundaryAnchor(1), null);
 var optionalView:BoundaryContainer<Dynamic,Dynamic> = optional;
 optionalView.value = [21]; if (optional.value[0] != 21) return 19;
 rejected = false;
 try optionalView.value = [2.5] catch (_:Dynamic) rejected = true;
 if (!rejected || optional.value[0] != 21) return 20;
 optionalView.value = null; if (optional.value != null) return 21;
 var elements = new BoundaryContainer<BoundaryAnchor,Array<BoundaryElement>>(new BoundaryAnchor(1), [new BoundaryElement(7,"yes")]);
 var elementView:BoundaryContainer<Dynamic,Dynamic> = elements;
 rejected = false;
 try elementView.value = [new BoundaryObject(9)] catch (_:Dynamic) rejected = true;
 if (!rejected || elements.value[0].number != 7 || elements.value[0].text != "yes") return 5;
 var otherElements:Array<BoundaryElement> = [new BoundaryElement(11,"ok")]; elementView.value = otherElements;
 if (elements.value != otherElements || elements.value[0].number != 11) return 6;
 var dynamicElements:Array<Dynamic> = [new BoundaryElement(17,"dynamic")]; elementView.value = dynamicElements;
 if (elements.value[0].number != 17 || (cast dynamicElements[0]:BoundaryElement).text != "dynamic") return 15;
 rejected = false;
 var invalidElements:Array<Dynamic> = [new BoundaryElement(18,"kept"), new BoundaryObject(19)];
 try elementView.value = invalidElements catch (_:Dynamic) rejected = true;
 if (!rejected || elements.value[0].number != 17 || (cast invalidElements[0]:BoundaryElement).number != 18) return 16;
 var refs = new BoundaryContainer<BoundaryAnchor,Array<BoundaryObject>>(new BoundaryAnchor(1), [new BoundaryObject(13)]);
 var refView:BoundaryContainer<Dynamic,Dynamic> = refs;
 rejected = false;
 try refView.value = otherElements catch (_:Dynamic) rejected = true;
 if (!rejected || refs.value[0].number != 13) return 7;
 var callbacks = new BoundaryContainer<BoundaryAnchor,Int->Int>(new BoundaryAnchor(1), increment);
 var callbackView:BoundaryContainer<Dynamic,Dynamic> = callbacks;
 rejected = false;
 try callbackView.value = "wrong" catch (_:Dynamic) rejected = true;
 if (!rejected || callbacks.value(41) != 42) return 8;
 rejected = false;
 try callbackView.value = twoArgs catch (_:Dynamic) rejected = true;
 if (!rejected || callbacks.value(41) != 42) return 9;
 rejected = false;
 try callbackView.value = floatIdentity catch (_:Dynamic) rejected = true;
 if (!rejected || callbacks.value(41) != 42) return 10;
 callbackView.value = increment; if (callbacks.value(41) != 42) return 11;
 var calculator = new BoundaryCalculator(); callbackView.value = calculator.increment;
 if (callbacks.value(41) != 42) return 18;
 callbackView.value = null; if (callbacks.value != null) return 12;
 var valueCallbacks = new BoundaryContainer<BoundaryAnchor,BoundaryElement->BoundaryElement>(new BoundaryAnchor(1), elementIdentity);
 var valueCallbackView:BoundaryContainer<Dynamic,Dynamic> = valueCallbacks;
 rejected = false;
 try valueCallbackView.value = twoArgs catch (_:Dynamic) rejected = true;
 if (!rejected || valueCallbacks.value(new BoundaryElement(1,"a")).number != 1) return 13;
 rejected = false;
 try valueCallbackView.value = otherElementIdentity catch (_:Dynamic) rejected = true;
 if (!rejected || valueCallbacks.value(new BoundaryElement(1,"a")).number != 1) return 17;
 valueCallbackView.value = elementIdentity;
 if (valueCallbacks.value(new BoundaryElement(42,"ok")).number != 42) return 14;
 BoundaryClosureCensus.prepare();
 #if !wasm
 var before = hl.Gc.totalAllocated();
 #end
 if (BoundaryClosureCensus.perform(8) != 8 || BoundaryClosureCensus.perform(1024) != 1024) return 22;
 #if !wasm
 if (hl.Gc.totalAllocated() != before) return 23;
 #end
 return 42;
}
