class StoreOwner {
	public var id:Int;
	public function new(id:Int) this.id = id;
}

struct StoreInner {
	public var owner:StoreOwner;
	public var number:Int;
	public function new(owner:StoreOwner, number:Int) { this.owner = owner; this.number = number; }
}

struct StoreValue {
	public var number:Int;
	public var inner:Null<StoreInner>;
	public function new(number:Int, inner:Null<StoreInner>) { this.number = number; this.inner = inner; }
}

class DynamicStoreCensus {
	static var items:Array<StoreValue>;
	static var view:Array<Dynamic>;
	static var present:Dynamic;
	static var absent:Dynamic;
	static var owner:StoreOwner;
	public static function prepare():Void {
		owner = new StoreOwner(2);
		present = new StoreValue(40, new StoreInner(owner, 7));
		absent = new StoreValue(42, null);
		items = []; items.resize(8); view = cast items;
		// Materialize a lazy reference lane before the measured window.
		view[0] = present;
	}
	public static function perform():Int {
		view[0] = absent;
		if (items[0].number != 42 || items[0].inner != null) return 1;
		view[0] = present;
		var saved = items[0];
		view.insert(0, absent);
		var moved = items[1].inner, snapshot = saved.inner;
		if (items[0].inner != null || moved == null || moved.owner != owner || snapshot == null || snapshot.number != 7) return 2;
		items.resize(8);
		return items[1].number + moved.owner.id;
	}
}

function main():Int {
	DynamicStoreCensus.prepare();
	if (DynamicStoreCensus.perform() != 42) return 1;
	#if !wasm
	for (count in [8, 1024]) {
		hl.Gc.censusStart(0);
		var before = hl.Gc.totalAllocated(), result = 0;
		for (_ in 0...count) result = DynamicStoreCensus.perform();
		var bytes = hl.Gc.totalAllocated() - before;
		hl.Gc.censusStop();
		if (result != 42 || bytes != 0) return 7;
	}
	#end
	var owner = new StoreOwner(3), items = [new StoreValue(39, new StoreInner(owner, 5))];
	var view:Array<Dynamic> = cast items, alias = items, failed = false;
	try { view[100] = "wrong type"; } catch (_:Dynamic) { failed = true; }
	var original = alias[0].inner;
	if (!failed || alias.length != 1 || alias[0].number != 39 || original == null || original.owner != owner) return 2;
	failed = false;
	try { view.insert(-100, "wrong type"); } catch (_:Dynamic) { failed = true; }
	original = alias[0].inner;
	if (!failed || alias.length != 1 || original == null || original.number != 5) return 3;
	var boxed:Dynamic = new StoreValue(42, null);
	view.insert(-100, boxed);
	original = alias[1].inner;
	if (alias.length != 2 || alias[0].inner != null || original == null || original.owner != owner) return 4;
	view[100] = boxed;
	if (alias.length != 101 || alias[100].number != 42 || alias[100].inner != null) return 5;
	var optional:Array<Null<StoreValue>> = [new StoreValue(39, new StoreInner(owner, 5))];
	var optionalView:Array<Dynamic> = cast optional;
	optionalView[0] = null;
	optionalView.insert(0, boxed);
	var first = optional[0];
	if (optional[1] != null || first == null || first.inner != null || first.number != 42) return 6;
	// First managed reference arrives while the scalar lane itself must grow.
	var fresh:Array<StoreValue> = [], freshView:Array<Dynamic> = cast fresh;
	var withOwner:Dynamic = new StoreValue(39, new StoreInner(owner, 5));
	freshView[100] = withOwner;
	var grown = fresh[100].inner;
	if (fresh.length != 101 || grown == null || grown.owner != owner || grown.number != 5) return 8;
	var inserted:Array<StoreValue> = []; inserted.resize(4);
	var insertedView:Array<Dynamic> = cast inserted;
	insertedView.insert(2, withOwner);
	var moved = inserted[2].inner;
	if (inserted.length != 5 || moved == null || moved.owner != owner || moved.number != 5) return 9;
	return 42;
}
