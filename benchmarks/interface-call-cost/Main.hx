// What a call through an interface value costs on HashLink today (an allocating virtual adapter's method slot), against a direct class call and
// against the dispatch the design note proposes (the interface value is the object; a call selects the implementation from the class).
// Build:  haxeon plain build of this file, run it, read the lines. Each figure is the best of several runs of CALLS calls, in ns per call.
interface Reader {
	function read():Int;
}

class Base implements Reader {
	public final id:Int;
	public var v:Int;

	public function new(id:Int, v:Int) {
		this.id = id;
		this.v = v;
	}

	public function read():Int
		return v;
}

class A extends Base {
	public function new(v:Int)
		super(0, v);

	override public function read():Int
		return v + 1;
}

class B extends Base {
	public function new(v:Int)
		super(1, v);

	override public function read():Int
		return v + 2;
}

class C extends Base {
	public function new(v:Int)
		super(2, v);

	override public function read():Int
		return v + 3;
}

class D extends Base {
	public function new(v:Int)
		super(3, v);

	override public function read():Int
		return v + 4;
}

class Main {
	static inline final COUNT = 1024;
	static inline final CALLS = 20000000;
	static inline final RUNS = 5;

	static function best(run:Void->Int):Float {
		var bestTime = 1e30, sink = 0;
		for (_ in 0...RUNS) {
			var start = Sys.time();
			sink += run();
			var elapsed = Sys.time() - start;
			if (elapsed < bestTime)
				bestTime = elapsed;
		}
		if (sink == 42)
			Sys.println("");
		return bestTime * 1e9 / CALLS;
	}

	static function main():Int {
		var direct:Array<A> = [],
			monoView:Array<Reader> = [],
			polyView:Array<Reader> = [],
			hierarchy:Array<Base> = [];
		for (i in 0...COUNT) {
			direct.push(new A(i));
			monoView.push(new A(i));
			var item:Base = switch i & 3 {
				case 0: new A(i);
				case 1: new B(i);
				case 2: new C(i);
				default: new D(i);
			};
			hierarchy.push(item);
			polyView.push(item);
		}
		var directCall = best(() -> {
			var s = 0;
			for (n in 0...CALLS)
				s += direct[n & (COUNT - 1)].read();
			return s;
		});
		var interfaceOne = best(() -> {
			var s = 0;
			for (n in 0...CALLS)
				s += monoView[n & (COUNT - 1)].read();
			return s;
		});
		var interfaceFour = best(() -> {
			var s = 0;
			for (n in 0...CALLS)
				s += polyView[n & (COUNT - 1)].read();
			return s;
		});
		// A class hierarchy: HashLink's own method table (the cost of "the interface value is the object" when the implementors share a base).
		var hierarchyCall = best(() -> {
			var s = 0;
			for (n in 0...CALLS)
				s += hierarchy[n & (COUNT - 1)].read();
			return s;
		});
		// The proposed form for unrelated implementors, by hand: read the class id from the object and select the implementation (a closed-world
		// switch over the implementors, the way the Wasm backends dispatch). The casts are unchecked.
		var idSwitch = best(() -> {
			var s = 0;
			for (n in 0...CALLS) {
				var o = hierarchy[n & (COUNT - 1)];
				s += switch o.id {
					case 0: (cast o : A).read();
					case 1: (cast o : B).read();
					case 2: (cast o : C).read();
					default: (cast o : D).read();
				};
			}
			return s;
		});
		function show(name:String, value:Float):Void
			Sys.println(StringTools.rpad(name, " ", 52) + Math.round(value * 100) / 100 + " ns/call");
		show("direct class call (final method, one class)", directCall);
		show("interface call today, one implementor", interfaceOne);
		show("interface call today, four implementors", interfaceFour);
		show("class method table (hierarchy, four classes)", hierarchyCall);
		show("class-id switch, four implementors (proposed)", idSwitch);
		return 42;
	}
}
