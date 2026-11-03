struct IteratorPoint {
	public var x:Int;
	public var label:String;
	public function new(x:Int, label:String) { this.x = x; this.label = label; }
}

class IteratorCensus {
	static var points:Array<IteratorPoint>;
	static var iterator:Iterator<IteratorPoint>;
	public static function prepare(count:Int):Void {
		points = [];
		for (index in 0...count) points.push(new IteratorPoint(index, "point"));
		iterator = points.iterator();
	}
	public static function perform():Int {
		var sum = 0;
		while (iterator.hasNext()) sum += iterator.next().x;
		return sum;
	}
}

function sumPoints(points:Iterable<IteratorPoint>):Int {
	var sum = 0;
	for (point in points) sum += point.x;
	return sum;
}

function main():Int {
	var points:Array<IteratorPoint> = [new IteratorPoint(42, "first"), new IteratorPoint(7, "second")];
	var iterator:Iterator<IteratorPoint> = points.iterator();
	if (!iterator.hasNext()) return 1;
	var copy = iterator.next();
	if (copy.x != 42 || copy.label != "first") return 2;
	copy.x = 1;
	if (points[0].x != 42) return 3;
	points.push(new IteratorPoint(3, "grown"));
	if (iterator.next().x != 7 || iterator.next().x != 3 || iterator.hasNext()) return 4;
	var exhausted = false;
	try iterator.next() catch (_:Dynamic) exhausted = true;
	if (!exhausted || sumPoints(points) != 52) return 5;
	IteratorCensus.prepare(1);
	if (IteratorCensus.perform() != 0) return 6;
	#if !wasm
	IteratorCensus.prepare(8);
	var smallBefore = hl.Gc.totalAllocated();
	if (IteratorCensus.perform() != 28 || hl.Gc.totalAllocated() != smallBefore) return 9;
	#end
	IteratorCensus.prepare(1024);
	#if !wasm
	var before = hl.Gc.totalAllocated();
	#end
	var sum = IteratorCensus.perform();
	#if !wasm
	if (hl.Gc.totalAllocated() != before) return 7;
	#end
	if (sum != 1024 * 1023 / 2) return 8;
	var optional:Array<Null<IteratorPoint>> = [null, new IteratorPoint(42, "optional")];
	var optionalIterator = optional.iterator();
	if (optionalIterator.next() != null) return 10;
	var present = optionalIterator.next();
	if (present == null || present.x != 42 || present.label != "optional" || optionalIterator.hasNext()) return 11;
	return 42;
}
