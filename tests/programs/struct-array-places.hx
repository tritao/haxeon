struct ArrayOffset {
	public var x:Int;
	public function new(x:Int) { this.x = x; }
	public function changeThenThrow():Void { x += 3; throw "changed"; }
	public function around(callback:Void->Void):Void { x += 1; callback(); x += 2; }
}

class ArrayMarker {
	public var value:Int;
	public function new(value:Int) { this.value = value; }
}

struct ArrayRecord {
	public var offset:ArrayOffset;
	public var text:String;
	public var optional:Null<ArrayOffset>;
	public var marker:ArrayMarker;
	public function new(x:Int, text:String, optional:Null<ArrayOffset>) {
		this.offset = new ArrayOffset(x);
		this.text = text;
		this.optional = optional;
		this.marker = new ArrayMarker(x);
	}
}

function main():Int {
	var records:Array<ArrayRecord> = [];
	for (i in 0...64) records.push(new ArrayRecord(i, "item", i == 0 ? new ArrayOffset(7) : null));
	var copy = records[0];
	copy.offset.x = 100;
	var optional = copy.optional;
	if (records[0].offset.x != 0 || copy.text != "item" || optional == null || optional.x != 7) return 1;
	var alias = records;
	alias[0].offset.x = 4;
	if (records[0].offset.x != 4) return 2;
	try { records[0].offset.changeThenThrow(); } catch (error:Dynamic) {}
	if (alias[0].offset.x != 7) return 3;
	var sum = 0;
	for (record in records) sum += record.offset.x;
	if (sum != 2023) return 4;
	var snapshot = records.copy();
	var slice = records.slice(0, 2);
	var concatenated = records.concat([]);
	records[1].offset.x = 50;
	var failures = 0;
	if (snapshot[1].offset.x != 1) failures += 1;
	if (slice[1].offset.x != 1) failures += 2;
	if (concatenated[1].offset.x != 1) failures += 4;
	if (records[1].offset.x != 50) failures += 8;
	snapshot[1].offset.x = 70;
	if (records[1].offset.x != 50 || snapshot[1].marker != records[1].marker) failures += 64;
	// Growth during a method call must not redirect the pending write to an old backing store.
	records[0].offset.around(function() {
		if (records[0].offset.x != 8) throw "write not visible during callback";
		for (i in 0...128) records.push(new ArrayRecord(i, "grown", null));
		records[0].offset.x = 20;
	});
	if (records[0].offset.x != 22 || records.length != 192) failures += 16;
	var nullable:Array<Null<ArrayRecord>> = [new ArrayRecord(9, "nullable", null), null];
	var nullableCopy = nullable.copy();
	var copiedFirst = nullableCopy[0];
	if (copiedFirst == null || copiedFirst.offset.x != 9 || nullableCopy[1] != null) failures += 32;
	var grown:Array<ArrayRecord> = [];
	grown.resize(3);
	grown[1] = new ArrayRecord(13, "initialized", null);
	var grownCopy = grown.copy();
	var grownSlice = grown.slice(0, 2);
	var grownConcat = grown.concat([]);
	grown[1].offset.x = 14;
	if (grownCopy.length != 3 || grownSlice.length != 2 || grownConcat.length != 3
		|| grownCopy[1].offset.x != 13 || grownSlice[1].offset.x != 13 || grownConcat[1].offset.x != 13) failures += 128;
	return failures == 0 ? 42 : 1;
}
