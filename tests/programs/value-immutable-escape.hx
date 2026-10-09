@:value
class Padding {
	public final left:Float;
	public final top:Float;
	public final right:Float;
	public final bottom:Float;
	public function new(seed:Int) {
		left = seed + 1.0;
		top = seed + 2.0;
		right = seed + 3.0;
		bottom = seed + 4.0;
	}
}
@:value
class Nested {
	public final padding:Padding;
	public final tag:Int;
	public function new(seed:Int) {
		padding = new Padding(seed);
		tag = seed;
	}
}
class Holder {
	public var padding:Padding;
	public var nested:Nested;
	public function new(seed:Int) {
		padding = new Padding(seed);
		nested = new Nested(seed);
	}
}
class Retained {
	public static var boxes:Array<Dynamic> = [];
	public static var typed:Array<Padding> = [];
	public static var callbacks:Array<Void->Float> = [];
	public static var nested:Array<Nested> = [];
	public static var mapped:Map<Int, Padding> = [];
}
function returned(holder:Holder):Padding return holder.padding;
function boxed(value:Padding):Dynamic return value;
function capture(holder:Holder):Void->Float {
	var padding = holder.padding;
	return () -> padding.bottom;
}
function retain(seed:Int):Void {
	var holder = new Holder(seed);
	Retained.boxes.push(holder.padding);
	Retained.boxes.push(boxed(holder.padding));
	Retained.typed.push(returned(holder));
	Retained.callbacks.push(capture(holder));
	Retained.nested.push(holder.nested);
	Retained.mapped.set(seed, holder.padding);
	var optional:Null<Padding> = holder.padding;
	Retained.boxes.push(optional);
	var absent:Null<Padding> = null;
	Retained.boxes.push(absent);
	// Retained values must survive replacement of their original inline slot.
	holder.padding = new Padding(-100);
}
function churn(seed:Int):Int {
	var total = 0;
	for (i in 0...100000) {
		var values = [seed, i, i + 1];
		total += values.length;
	}
	return total;
}
function main():Int {
	for (i in 0...1000) retain(i);
	for (round in 0...8) {
		if (churn(round) != 300000) return 1;
		hl.Gc.major();
		for (i in 0...1000) {
			var direct:Padding = cast Retained.boxes[i * 4];
			var argument:Padding = cast Retained.boxes[i * 4 + 1];
			var optional:Null<Padding> = cast Retained.boxes[i * 4 + 2];
			if (direct.left != i + 1 || argument.bottom != i + 4) return 2;
			if (optional == null || optional.right != i + 3 || Retained.boxes[i * 4 + 3] != null) return 3;
			if (Retained.typed[i].top != i + 2 || Retained.callbacks[i]() != i + 4) return 4;
			if (Retained.nested[i].tag != i || Retained.nested[i].padding.bottom != i + 4) return 5;
			var mapped = Retained.mapped.get(i);
			if (mapped == null || mapped.left != i + 1) return 6;
		}
	}
	return 42;
}
