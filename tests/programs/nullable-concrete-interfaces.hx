interface Readable {
	function read():Int;
}

interface Writable {
	function write():Int;
}

class Value implements Readable implements Writable {
	public function new() {}

	public function read():Int
		return 40;

	public function write():Int
		return 2;
}

class Reader {
	public function new(?value:Readable) {}
}

class Writer {
	public function new(?value:Writable) {}
}

function probe(flag:Bool):Int {
	var value = flag ? new Value() : null;
	var reader = value == null ? null : new Reader(value);
	var writer = new Writer(value);
	var fromSwitch = switch (flag ? 1 : 0) {
		case 1:
			new Value();
		default:
			null;
	};
	var switchReader = new Reader(fromSwitch);
	var switchWriter = new Writer(fromSwitch);
	return value == null ? 0 : value.read() + value.write();
}

function main():Int
	return probe(true);
