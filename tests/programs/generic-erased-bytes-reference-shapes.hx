struct ByteShapeAnchor { public final id:Int; public function new(id:Int) this.id=id; }
class ByteShapeHolder<A,B> { public var anchor:A; public var value:B; public var storage:Array<B>; public function new(a:A,b:B) { anchor=a; value=b; storage=null; } }
function main():Int {
 var strings = new ByteShapeHolder<ByteShapeAnchor,String>(new ByteShapeAnchor(1),"kept");
 var stringView:ByteShapeHolder<Dynamic,Dynamic> = strings; var stringRejected=false;
 try stringView.value = haxe.io.Bytes.alloc(3) catch (_:Dynamic) stringRejected=true;
 var bytes = new ByteShapeHolder<ByteShapeAnchor,haxe.io.Bytes>(new ByteShapeAnchor(2),haxe.io.Bytes.alloc(3));
 var byteView:ByteShapeHolder<Dynamic,Dynamic> = bytes; var bytesRejected=false;
 try byteView.value = "wrong" catch (_:Dynamic) bytesRejected=true;
 if (stringRejected && bytesRejected) return 42;
 return 1;
}
