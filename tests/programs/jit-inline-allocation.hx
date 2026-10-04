class Empty8 {
	public function new() {}
}

class SmallInt16 {
	public var value:Int;

	public function new() {}
}

class Small16 {
	public var a:Float;

	public function new() {}
}

class Small24 {
	public var a:Float;
	public var b:Float;

	public function new() {}
}

class Small32 {
	public var a:Float;
	public var b:Float;
	public var c:Float;

	public function new() {}
}

class Small40 {
	public var a:Float;
	public var b:Float;
	public var c:Float;
	public var d:Float;

	public function new() {}
}

class Links {
	public var next:Links;
	public var text:String;

	public function new() {}
}

@:noInline function pressure(n:Int):Float {
	var a = 1.0, b = 2.0, c = 3.0, d = 4.0, e = 5.0, f = 6.0;
	var keep:Array<Links> = [];
	for (i in 0...n) {
		var sentinel = a + 0.25;
		var empty = new Empty8();
		var integer = new SmallInt16();
		if (empty == null || integer.value != 0)
			return -3.0;
		integer.value = 42;
		var x = new Small16();
		var y = new Small24();
		var z = new Small32();
		var w = new Small40();
		var link = new Links();
		if (x.a != 0.0 || y.a != 0.0 || y.b != 0.0 || z.a != 0.0 || z.b != 0.0 || z.c != 0.0 || w.a != 0.0 || w.b != 0.0 || w.c != 0.0 || w.d != 0.0
			|| link.next != null || link.text != null)
			return -1.0;
		x.a = 42.0;
		y.a = 42.0;
		y.b = 43.0;
		z.a = 42.0;
		z.b = 43.0;
		z.c = 44.0;
		w.a = 42.0;
		w.b = 43.0;
		w.c = 44.0;
		w.d = 45.0;
		a = sentinel + 0.75;
		link.text = "alive";
		keep[i & 127] = link;
		b += 2.0;
		c += 3.0;
		d += 4.0;
		e += 5.0;
		f += 6.0;
	}
	for (link in keep)
		if (link.text != "alive")
			return -2.0;
	return a + b + c + d + e + f;
}

function main():Int {
	var result = pressure(20000);
	if (result != 420021.0)
		return 1;
	var caught = false;
	var live = new Links();
	live.text = "live";
	try {
		if (pressure(1000) != 21021.0)
			return 2;
		throw "expected";
	} catch (e:Dynamic) {
		caught = true;
	}
	return caught && live.text == "live" ? 42 : 3;
}
