interface Readable {
	function read():Int;
}

interface Writable {
	function write():Int;
}

class Value implements Readable implements Writable {
	public function new() {}
	public function read():Int return 40;
	public function write():Int return 2;
}

function main():Int
	return new Value().read() + new Value().write();
