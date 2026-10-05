class SharedCell {
	public var left:SharedCell;
	public var right:SharedCell;
	public var common:SharedCell;
	public var value:Int;

	public function new(previous:SharedCell, common:SharedCell, value:Int) {
		left = previous;
		right = previous;
		this.common = common;
		this.value = value;
	}
}

function makeGraph(size:Int):SharedCell {
	var common = new SharedCell(null, null, 42);
	common.left = common;
	common.right = common;
	common.common = common;
	var root:SharedCell = null;
	for (i in 0...size)
		root = new SharedCell(root, common, i);
	return root;
}

function main():Int {
	var size = 30000;
	var root = makeGraph(size);
	for (round in 0...16) {
		hl.Gc.major();
		var common = root.common;
		if (common.value != 42 || common.left != common || common.right != common || common.common != common)
			return 1;
		var cursor = root;
		var count = 0;
		var checksum = 0;
		while (cursor != null) {
			if (cursor.left != cursor.right || cursor.common != common || cursor.value != size - count - 1)
				return 2;
			checksum ^= cursor.value;
			cursor = cursor.left;
			count++;
		}
		if (count != size || checksum != 0)
			return 3;
		var garbage:Array<SharedCell> = [];
		for (i in 0...10000)
			garbage.push(new SharedCell(null, common, i));
		if (garbage.length != 10000)
			return 4;
	}
	return 42;
}
