class DynamicCallbackOwner {
	public final id:Int;
	public function new(id:Int) this.id = id;
}

struct DynamicCallbackInner {
	public var number:Int;
	public var owner:DynamicCallbackOwner;
	public function new(number:Int, owner:DynamicCallbackOwner) { this.number = number; this.owner = owner; }
}

struct DynamicCallbackValue {
	public var inner:DynamicCallbackInner;
	public final name:String;
	public function new(number:Int, owner:DynamicCallbackOwner, name:String) {
		inner = new DynamicCallbackInner(number, owner); this.name = name;
	}
}

class DynamicCallbackHost {
	public static var saved:Dynamic;
	public static function identity(value:Dynamic):Dynamic { saved = value; hl.Gc.major(); return value; }
	public static function fail(value:Dynamic):Dynamic throw "expected";
}

function makeSavedCallbackValue():Dynamic {
	var owner = new DynamicCallbackOwner(91);
	var callbacks:Array<DynamicCallbackValue->DynamicCallbackValue> = [];
	var genuine:Dynamic = DynamicCallbackHost.identity;
	callbacks.push(cast genuine);
	callbacks[0](new DynamicCallbackValue(33, owner, "rooted"));
	return DynamicCallbackHost.saved;
}

function main():Int {
	var owner = new DynamicCallbackOwner(37), original = new DynamicCallbackValue(42, owner, "kept");
	var listeners:Array<DynamicCallbackValue->DynamicCallbackValue> = [];
	var genuine:Dynamic = DynamicCallbackHost.identity;
	var view:DynamicCallbackValue->DynamicCallbackValue = cast genuine;
	listeners.push(view);
	var result = listeners[0](original);
	if (result.inner.number != 42 || result.inner.owner != owner || result.name != "kept") return 1;
	result.inner.number = 7;
	if (original.inner.number != 42) return 2;
	original.inner.number = 9;
	hl.Gc.major();
	var saved:DynamicCallbackValue = cast DynamicCallbackHost.saved;
	if (saved.inner.number != 42 || saved.inner.owner != owner || saved.name != "kept") return 3;
	var second = listeners[0](new DynamicCallbackValue(5, owner, "again"));
	if (second.inner.number != 5 || second.inner.owner != owner || second.name != "again") return 4;
	var onlyRoot = makeSavedCallbackValue();
	DynamicCallbackHost.saved = null;
	hl.Gc.major();
	var afterGc:DynamicCallbackValue = cast onlyRoot;
	if (afterGc.inner.number != 33 || afterGc.inner.owner.id != 91 || afterGc.name != "rooted") return 5;
	afterGc.inner.number = 14;
	var afterGcAgain:DynamicCallbackValue = cast onlyRoot;
	if (afterGcAgain.inner.number != 33 || afterGcAgain.inner.owner.id != 91) return 8;
	var caught = false;
	var failure:Dynamic = DynamicCallbackHost.fail, failureView:DynamicCallbackValue->DynamicCallbackValue = cast failure;
	caught = false;
	try failureView(original) catch (_:Dynamic) caught = true;
	if (!caught || original.inner.number != 9) return 7;
	return 42;
}
