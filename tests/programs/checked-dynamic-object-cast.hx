interface CastReadable {
	function read():Int;
}

class CastBase {
	public function new() {}
}

class CastChild extends CastBase implements CastReadable {
	public function new() super();
	public function read():Int return 42;
}

class CastOther {
	public function new() {}
}

function main():Int {
	var child:Dynamic = new CastChild();
	var base:CastBase = cast child;
	if (base == null) return 1;
	var readable:CastReadable = cast child;
	if (readable.read() != 42) return 5;
	var absent:Dynamic = null;
	var nullable:CastBase = cast absent;
	if (nullable != null) return 2;
	var other:Dynamic = new CastOther();
	var caught = false;
	try {
		var invalid:CastBase = cast other;
		if (invalid != null) return 3;
	} catch (_:Dynamic) caught = true;
	if (!caught) return 4;
	caught = false;
	try {
		var invalid:CastReadable = cast other;
		if (invalid != null) return 6;
	} catch (_:Dynamic) caught = true;
	return caught ? 42 : 7;
}
