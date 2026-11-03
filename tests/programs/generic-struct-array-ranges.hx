class RangeOwner {
	public var number:Int;
	public function new(number:Int) this.number = number;
}

struct RangeValue {
	public var number:Int;
	public var owner:RangeOwner;
	public function new(number:Int, owner:RangeOwner) { this.number = number; this.owner = owner; }
}

function duplicateRanges<T>(source:Array<T>):Array<T> {
	return source.copy().concat(source.slice(0, source.length));
}

class GenericRangeCensus {
	static var values:Array<RangeValue>;
	static var owner:RangeOwner;
	public static function prepare(n:Int):Void {
		owner = new RangeOwner(4);
		values = [];
		for (index in 0...n) values.push(new RangeValue(index, owner));
	}
	public static function perform():Int {
		var copies = duplicateRanges(values);
		copies[0].number = 42;
		return values[0].number == 0 && copies[0].owner == owner && copies[values.length].number == 0 ? 42 : 1;
	}
}

function main():Int {
	GenericRangeCensus.prepare(8);
	return GenericRangeCensus.perform();
}
