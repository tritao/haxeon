@:hlNative("jitalloc") extern class Hooks {
	static function mode(value:Int):Void;
	static function count():Int;
	static function major():Void;
	static function padding(value:Dynamic):Bool;
}

class Node24 {
	public var a:Float;
	public var b:Float;

	public inline function new() {}
}

class Padding24 {
	public var next:Padding24;
	public var value:Int;

	public function new() {}
}

class JitAllocationProbe {
	static var sink:Node24;

	@:noInline static function pure(n:Int):Float {
		var a = 1.0, b = 2.0, c = 3.0, d = 4.0, e = 5.0, f = 6.0;
		for (i in 0...n) {
			var old = sink;
			var node = new Node24();
			if (node.a != 0.0 || node.b != 0.0)
				throw "dirty pure";
			node.a = 42.0;
			node.b = 43.0;
			sink = node;
			if (old != null && old.b != 43.0)
				throw "lost pointer on refill";
			a += 1.0;
			b += 2.0;
			c += 3.0;
			d += 4.0;
			e += 5.0;
			f += 6.0;
		}
		return a + b + c + d + e + f;
	}

	@:noInline static function allocate(n:Int):Float {
		var keep:Array<Node24> = [];
		var sum = 0.0;
		for (i in 0...n) {
			var node = new Node24();
			if (node.a != 0.0 || node.b != 0.0)
				throw "dirty default";
			node.a = 42.0;
			node.b = 43.0;
			keep[i & 127] = node;
			sum += node.a;
		}
		for (node in keep)
			if (node.b != 43.0)
				throw "lost live pointer";
		return sum;
	}

	static function main() {
		if (allocate(1000) != 42000.0)
			throw "warmup";
		Hooks.major();
		if (allocate(17) != 714.0)
			throw "ready callback run";
		Hooks.mode(1);
		if (allocate(1000) != 42000.0 || Hooks.count() != 1000)
			throw "callback guard";
		Hooks.mode(0);
		if (allocate(17) != 714.0)
			throw "ready census run";
		Hooks.mode(2);
		if (allocate(1000) != 42000.0)
			throw "census guard";
		Hooks.mode(0);
		if (allocate(17) != 714.0)
			throw "ready tracking run";
		Hooks.mode(3);
		var trackedResult = allocate(1000);
		var trackedCount = Hooks.count();
		if (trackedResult != 42000.0 || trackedCount < 1000)
			throw "tracking guard: " + trackedCount;
		Hooks.mode(0);
		Hooks.major();
		if (allocate(10000) != 420000.0)
			throw "re-enable";
		var pads:Array<Padding24> = [];
		for (i in 0...20000) {
			var pad = new Padding24();
			if (pad.next != null || pad.value != 0 || !Hooks.padding(pad))
				throw "pointer padding";
			pad.value = 42;
			pads[i & 127] = pad;
			if ((i & 1023) == 1023)
				Hooks.major();
		}
		if (pure(1000000) != 21000021.0 || !Std.isOfType(sink, Node24))
			throw "slow-edge preservation/type";
		Sys.println("PASS: JIT dirty-page defaults and hooks enabled after compilation");
	}
}
