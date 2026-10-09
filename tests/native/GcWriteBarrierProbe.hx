import hl.Gc;

private class BarrierCell {
	public var next:BarrierCell;
	public var links:Array<BarrierCell>;

	public function new(next:BarrierCell) {
		this.next = next;
		links = [next];
	}
}

class GcWriteBarrierProbe {
	static var head:BarrierCell;

	static function capture(cell:BarrierCell):Void->BarrierCell {
		return function() return cell;
	}

	static function exerciseNativePaths(cell:BarrierCell) {
		var object:Dynamic = {next: cell};
		var view:{next:BarrierCell} = object;
		Reflect.setField(object, "extra", cell);
		Reflect.setField(object, "count", 1);
		Reflect.setField(object, "count", cell); // scalar-to-pointer storage replacement
		var copied = Reflect.copy(object);
		Reflect.deleteField(object, "extra");
		if (view.next != cell || Reflect.field(copied, "count") != cell)
			throw 'dynamic remap/copy';
		var ints = new haxe.ds.IntMap<BarrierCell>();
		var strings = new haxe.ds.StringMap<BarrierCell>();
		var objects = new haxe.ds.ObjectMap<BarrierCell, BarrierCell>();
		var objectKeys = [];
		for (i in 0...200) {
			ints.set(i, cell);
			strings.set('key' + i, cell);
			var key = new BarrierCell(null);
			objectKeys.push(key);
			objects.set(key, cell);
		}
		ints.set(1, cell);
		strings.remove('key2');
		if (ints.copy().get(1) != cell || strings.copy().get('key199') != cell)
			throw 'map copy';
		for (key in objectKeys)
			if (objects.get(key) != cell)
				throw 'object map key';
		for (value in strings)
			if (value != cell)
				throw 'map values';
		ints.clear();
		strings.clear();
		if (ints.exists(1) || strings.exists('key199'))
			throw 'map clear';
		var closure = capture(cell);
		var dynamicClosure:Dynamic = closure;
		if (Reflect.callMethod(null, dynamicClosure, []) != cell)
			throw 'closure capture';
		var varargs = Reflect.makeVarArgs(function(args:Array<Dynamic>):Dynamic return cell);
		if (Reflect.callMethod(null, varargs, []) != cell)
			throw 'varargs capture';
	}

	static function main() {
		if (!Gc.incrementalSupported())
			return;
		Gc.enable(false);
		for (_ in 0...100000)
			head = new BarrierCell(head);
		if (Gc.step(0.001))
			throw 'expected pending cycle';
		var added = 0;
		var done = false;
		for (_ in 0...10000) {
			for (_ in 0...32) {
				head = new BarrierCell(head);
				added++;
			}
			exerciseNativePaths(head);
			if (Gc.step(1000.0)) {
				done = true;
				break;
			}
		}
		if (!done)
			throw 'cycle did not complete';
		var count = 0;
		var cell = head;
		while (cell != null) {
			if (cell.links[0] != cell.next)
				throw 'lost array reference';
			cell = cell.next;
			count++;
		}
		if (count != 100000 + added)
			throw 'lost field reference';
		Gc.enable(true);
		Sys.println('PASS: shared-JIT stores, dynamic/virtual fields, map mutations/copies and closures with kernel dirty bits masked');
	}
}
