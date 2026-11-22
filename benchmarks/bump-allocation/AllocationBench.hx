class AllocationBench {
	static function main() {
		var args = Sys.args();
		var n = Std.parseInt(args[1]);
		if (n == null)
			throw "count";
		switch (args[0]) {
			case "16":
				var ring:Array<Node16> = [];
				var checksum = 0.0;
				for (i in 0...n) {
					var o = new Node16(i & 1023);
					ring[i & 255] = o;
					checksum += o.f0;
				}
				for (o in ring)
					checksum += o.f0;
				Sys.println(checksum);
			case "24":
				var ring:Array<Node24> = [];
				var checksum = 0.0;
				for (i in 0...n) {
					var o = new Node24(i & 1023);
					ring[i & 255] = o;
					checksum += o.f0;
				}
				for (o in ring)
					checksum += o.f0;
				Sys.println(checksum);
			case "40":
				var ring:Array<Node40> = [];
				var checksum = 0.0;
				for (i in 0...n) {
					var o = new Node40(i & 1023);
					ring[i & 255] = o;
					checksum += o.f0;
				}
				for (o in ring)
					checksum += o.f0;
				Sys.println(checksum);
			default:
				throw "size";
		}
	}
}

class Node16 {
	public var f0:Float;

	public function new(x:Float) {
		f0 = x + 0.0;
	}
}

class Node24 {
	public var f0:Float;
	public var f1:Float;

	public function new(x:Float) {
		f0 = x + 0.0;
		f1 = x + 1.0;
	}
}

class Node40 {
	public var f0:Float;
	public var f1:Float;
	public var f2:Float;
	public var f3:Float;

	public function new(x:Float) {
		f0 = x + 0.0;
		f1 = x + 1.0;
		f2 = x + 2.0;
		f3 = x + 3.0;
	}
}
