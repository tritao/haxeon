// Eval establishes the checksums. An indirect returning call stays visible even with the inliner enabled.
function clobber(seed:Int):Int {
	var a = seed * 0.125;
	var b = a + 0.25;
	var c = b + 0.5;
	var d = c + 1.0;
	var e = d + 2.0;
	var f = e + 4.0;
	return Std.int(a + b + c + d + e + f);
}

function accumulate(count:Int, call:Int->Int):Float {
	var sum = 0.0;
	for (i in 0...count) {
		if ((i & 31) == 0)
			sum += call(i) * 0.125;
		sum += (i & 7) * 0.125;
	}
	return sum;
}

function directAccumulate(count:Int):Float {
	var sum = 0.0;
	for (i in 0...count) {
		if ((i & 31) == 0)
			sum += clobber(i) * 0.125;
		sum += (i & 7) * 0.125;
	}
	return sum;
}

function exceptional(call:Int->Int):Float {
	var sum = 0.0;
	try {
		for (i in 0...100) {
			sum += 0.125;
			if (i == 63)
				call(i);
		}
	} catch (error:Dynamic) {
		return sum;
	}
	return -1.0;
}

function main():Int {
	if (accumulate(1000, clobber) != 1981.5)
		return 1;
	if (exceptional(function(i:Int):Int {
		throw "expected";
	}) != 8.0)
		return 2;
	if (directAccumulate(1000) != 1981.5)
		return 4;
	if (rootChecksum(makeRoot, collectRoots) != 420)
		return 3;
	return 42;
}

class RootBox {
	public var a:Int;
	public var b:Int;
	public var c:Int;
	public var d:Int;
	public var e:Int;
	public var f:Int;
	public var g:Int;
	public var h:Int;

	public function new(seed:Int) {
		a = seed;
		b = seed + 1;
		c = seed + 2;
		d = seed + 3;
		e = seed + 4;
		f = seed + 5;
		g = seed + 6;
		h = seed + 7;
	}
}

function makeRoot(seed:Int):RootBox {
	return new RootBox(seed);
}

function collectRoots():Void {
	#if eval
	eval.vm.Gc.full_major();
	#else
	hl.Gc.major();
	#end
}

function rootChecksum(make:Int->RootBox, collect:Void->Void):Int {
	// Opaque factories prevent scalar replacement. Distinct fields keep enough
	// real pointer uses to exercise caller-saved roots beyond the five GPRs.
	var p = make(1), q = make(2), r = make(3), s = make(4);
	var t = make(5), u = make(6), v = make(7);
	collect();
	return p.a + p.b + p.c + p.d + p.e + p.f + p.g + p.h + q.a + q.b + q.c + q.d + q.e + q.f + q.g + q.h + r.a + r.b + r.c + r.d + r.e + r.f + r.g + r.h
		+ s.a + s.b + s.c + s.d + s.e + s.f + s.g + s.h + t.a + t.b + t.c + t.d + t.e + t.f + t.g + t.h + u.a + u.b + u.c + u.d + u.e + u.f + u.g + u.h + v.a
		+ v.b + v.c + v.d + v.e + v.f + v.g + v.h;
}
