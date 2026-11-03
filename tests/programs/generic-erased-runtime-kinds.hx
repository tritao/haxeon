struct RuntimeKindAnchor { public final id:Int; public function new(id:Int) this.id = id; }
class RuntimeKindBox<A,B> {
 public var anchor:A; public var value:B; public var storage:Array<B>;
 public function new(anchor:A, value:B) { this.anchor = anchor; this.value = value; storage = null; }
}
function runtimeKindCallback(value:Int):Int return value;
function main():Int {
 var bytes = new RuntimeKindBox<RuntimeKindAnchor,haxe.io.Bytes>(new RuntimeKindAnchor(1),haxe.io.Bytes.alloc(3));
 var bytesView:RuntimeKindBox<Dynamic,Dynamic> = bytes; var rejected = false;
 try bytesView.value = 12 catch (_:Dynamic) rejected = true;
 if (!rejected || bytes.value.length != 3) return 1;
 rejected = false;
 try bytesView.value = runtimeKindCallback catch (_:Dynamic) rejected = true;
 if (!rejected || bytes.value.length != 3) return 10;
 var replacement = haxe.io.Bytes.alloc(5); bytesView.value = replacement;
 if (bytes.value != replacement || bytes.value.length != 5) return 2;
 bytesView.value = null; if (bytes.value != null) return 3;
 var map:Map<String,Int> = []; map.set("a", 3);
 var maps = new RuntimeKindBox<RuntimeKindAnchor,Map<String,Int>>(new RuntimeKindAnchor(1),map);
 var mapView:RuntimeKindBox<Dynamic,Dynamic> = maps; rejected = false;
 try mapView.value = 12 catch (_:Dynamic) rejected = true;
 if (!rejected || maps.value.get("a") != 3) return 4;
 var second:Map<String,Int> = []; second.set("b", 7); mapView.value = second;
 if (maps.value != second || maps.value.get("b") != 7) return 5;
 mapView.value = null; if (maps.value != null) return 6;
 var item:Iterator<Int> = [8,9].iterator();
 var iterators = new RuntimeKindBox<RuntimeKindAnchor,Iterator<Int>>(new RuntimeKindAnchor(1),item);
 var iteratorView:RuntimeKindBox<Dynamic,Dynamic> = iterators; rejected = false;
 try iteratorView.value = 12 catch (_:Dynamic) rejected = true;
 if (!rejected || iterators.value.next() != 8) return 7;
 var next:Iterator<Int> = [13].iterator(); iteratorView.value = next;
 if (iterators.value.next() != 13) return 8;
 iteratorView.value = null; return iterators.value == null ? 42 : 9;
}
