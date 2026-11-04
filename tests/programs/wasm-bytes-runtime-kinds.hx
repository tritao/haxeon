struct BytesKindAnchor { public final id:Int; public function new(id:Int) this.id = id; }
class BytesKindHolder<A, B> {
 public var anchor:A;
 public var value:B;
 public var storage:Array<B>;
 public function new(anchor:A, value:B) { this.anchor=anchor; this.value=value; storage=null; }
}
class BytesIteratorCensus {
 static var numbers:Array<Int>;
 public static function prepare():Void numbers=[7,8,9];
 public static function iterate(count:Int):Int {
  var sum=0;
  for (_ in 0...count) {
   var iterator=numbers.iterator();
   var escaped:Dynamic=iterator;
   if (escaped == null) return -1;
   sum+=iterator.next();
  }
  return sum;
 }
 public static function allocateBytes(count:Int):Int {
  var sum=0;
  for (_ in 0...count) sum+=haxe.io.Bytes.alloc(4).length;
  return sum;
 }
}
function checkString(value:String):Bool {
 var holder=new BytesKindHolder<BytesKindAnchor,String>(new BytesKindAnchor(1), value);
 var view:BytesKindHolder<Dynamic,Dynamic>=holder;
 var rejected=false;
 try view.value=haxe.io.Bytes.ofString("wrong") catch (_:Dynamic) rejected=true;
 if (!rejected || holder.value != value) return false;
 view.value=value;
 return holder.value == value;
}
function checkBytes(value:haxe.io.Bytes):Bool {
 var holder=new BytesKindHolder<BytesKindAnchor,haxe.io.Bytes>(new BytesKindAnchor(1), value);
 var view:BytesKindHolder<Dynamic,Dynamic>=holder;
 var rejected=false;
 try view.value="wrong" catch (_:Dynamic) rejected=true;
 if (!rejected || holder.value != value) return false;
 view.value=value;
 return holder.value == value;
}
function main():Int {
 var original=haxe.io.Bytes.ofString("hello");
 var slice=original.sub(1,3), view=haxe.io.Bytes.view(original,1,3);
 var input=new haxe.io.BytesInput(original);
 var read=input.read(2), readString=input.readString(3);
 var output=new haxe.io.BytesOutput(); output.writeString("hello");
 var produced=output.getBytes();
 var distinctA:Dynamic=haxe.io.Bytes.ofString("same"), distinctB:Dynamic=haxe.io.Bytes.ofString("same");
 if (distinctA == distinctB) return 4;
 if (!checkBytes(haxe.io.Bytes.alloc(4)) || !checkBytes(original) || !checkBytes(slice)
  || !checkBytes(view) || !checkBytes(read) || !checkBytes(produced)) return 1;
 if (!checkString("literal") || !checkString(original.toString()) || !checkString(original.getString(1,3))
  || !checkString(readString) || !checkString("hel" + "lo") || !checkString("hello".substr(1,3))) return 2;
 for (i in 0...64) haxe.io.Bytes.alloc(i);
 if (view.get(0) != 101 || view.get(2) != 108 || read.toString() != "he" || readString != "llo") return 3;
 return 42;
}
