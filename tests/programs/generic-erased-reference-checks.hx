struct ReferenceBoundaryValue { public final number:Int; public function new(number:Int) this.number = number; }
enum ReferenceBoundaryTag implements Hashable { Empty; Number(value:Int); }
enum OtherBoundaryTag { Other; }
interface BoundaryInterface { public function number():Int; }
class BoundaryImplementation implements BoundaryInterface {
	public function new() {}
	public function number():Int return 42;
}
class ReferenceBoundary<A, B> {
	public var anchor:A;
	public var value:B;
	public var storage:Array<B>;
	public function new(anchor:A, value:B) { this.anchor = anchor; this.value = value; storage = null; }
}
function main():Int {
	var strings = new ReferenceBoundary<ReferenceBoundaryValue, String>(new ReferenceBoundaryValue(1), "kept");
	var stringView:ReferenceBoundary<Dynamic, Dynamic> = strings;
	var rejected = false;
	try stringView.value = 12 catch (_:Dynamic) rejected = true;
	if (!rejected || strings.value != "kept") return 1;
	stringView.value = "updated";
	if (strings.value != "updated") return 2;
	stringView.value = null;
	if (strings.value != null) return 3;
	var tags = new ReferenceBoundary<ReferenceBoundaryValue, ReferenceBoundaryTag>(new ReferenceBoundaryValue(1), Number(7));
	var tagView:ReferenceBoundary<Dynamic, Dynamic> = tags;
	rejected = false;
	try tagView.value = "wrong" catch (_:Dynamic) rejected = true;
	if (!rejected || tags.value != Number(7)) return 4;
	rejected = false;
	try tagView.value = Other catch (_:Dynamic) rejected = true;
	if (!rejected || tags.value != Number(7)) return 5;
	tagView.value = Number(9);
	if (tags.value != Number(9)) return 6;
	tagView.value = null;
	if (tags.value != null) return 7;
	var interfaces = new ReferenceBoundary<ReferenceBoundaryValue, BoundaryInterface>(new ReferenceBoundaryValue(1), new BoundaryImplementation());
	var interfaceView:ReferenceBoundary<Dynamic, Dynamic> = interfaces;
	rejected = false;
	try interfaceView.value = "wrong" catch (_:Dynamic) rejected = true;
	if (!rejected || interfaces.value.number() != 42) return 8;
	interfaceView.value = new BoundaryImplementation();
	if (interfaces.value.number() != 42) return 9;
	interfaceView.value = null;
	return interfaces.value == null ? 42 : 10;
}
