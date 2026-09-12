import haxe.io.Bytes;

class ReusedObject {
	public var value:Null<String>;

	public function new(?value:Null<String>) {
		if (value != null)
			this.value = value;
	}
}

function releaseObject():Void {
	var released = new ReusedObject("recycled allocation must not leak this value");
}

function releaseArray():Void {
	var released = new Array<Int>(1);
	released[0] = 99;
}

function releaseBytes():Void {
	var released = Bytes.alloc(16);
	released.set(0, 127);
}

function main():Int {
	// The next same-sized allocation reuses the just-collected object block.
	// A field with no initializer must still have its Haxe default value.
	releaseObject();
	var fresh = new ReusedObject();
	if (fresh.value != null)
		return 1;
	releaseArray();
	var freshArray = new Array<Int>(1);
	if (freshArray[0] != 0)
		return 2;
	releaseBytes();
	var freshBytes = Bytes.alloc(16);
	if (freshBytes.get(0) != 0)
		return 3;

	var retained = [40];
	var index = 0;
	while (index < 200) {
		var transient = [index];
		if (transient[0] < 0)
			return 0;
		index = index + 1;
	}
	return retained[0] + 2;
}
