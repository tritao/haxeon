import compiler.Frontend;
import compiler.ir.Ir;
import compiler.ir.IrAllocationReport;
import compiler.ir.IrAllocationReport.AllocationRootReport;
import compiler.ir.IrInliner;
import compiler.ir.IrInliner.IrInlineCache;
import compiler.ir.codec.IrFunctionStateCodec;

class AllocationReportMain {
	static final source = '
class Box { public var v:Int; public function new(v:Int) { this.v = v; } }
@:value class P { public var x:Float; public var y:Float; public function new(x:Float, y:Float) { this.x = x; this.y = y; } }
class Base { public function new() {} public function f():Int return 0; }
class Heavy extends Base { public function new() { super(); } override public function f():Int { var b = new Box(1); return b.v; } }
interface Shape { function area():Int; }
class Sq implements Shape { public function new() {} public function area():Int { var b = new Box(2); return b.v; } }
class T {
	public var items:Array<Int> = [];
	public var boxes:Map<Int, Box> = new Map();
	public var counts:Map<Int, Int> = new Map();
	public function new() {}
	public function pure(a:Int):Int return a * 2;
	public function newObj(a:Int):Int { var b = new Box(a); return b.v; }
	public function valueTemp(a:Float):Float { var p = new P(a, a); return p.x + p.y; }
	public function closure(a:Int):Int { var f = function(n:Int) return n + a; return f(1); }
	public function concat(a:String, n:Int):String return a + n;
	public function push(a:Int):Void items.push(a);
	public function setIdx(i:Int, a:Int):Void items[i] = a;
	public function mapGetRef(k:Int):Null<Box> return boxes.get(k);
	public function mapGetInt(k:Int):Null<Int> return counts.get(k);
	public function mapExists(k:Int):Bool return boxes.exists(k);
	public function mapIter():Int { var n = 0; for (v in boxes) n += v.v; return n; }
	public function arrIter():Int { var n = 0; for (v in items) n += v; return n; }
	public function loopy(n:Int):Int { var s = 0; for (i in 0...n) s += newObj(i); return s; }
	public function outer(n:Int):Int return loopy(n) + 1;
	public function guarded(n:Int):Int { if (n < 0) throw "negative: " + n; return n; }
	public function rec(n:Int):Int return n <= 0 ? 0 : rec(n - 1);
	public function dispatch(b:Base):Int return b.f();
	public function viaInterface(s:Shape):Int return s.area();
}
function main():Int { var t = new T(); return t.pure(1) + t.dispatch(new Heavy()) + t.viaInterface(new Sq()); }
';

	static function expect(ok:Bool, message:String):Void {
		if (!ok)
			throw message;
	}

	static function kinds(rows:Array<AllocationRootReport>, root:String):String {
		for (row in rows)
			if (row.root == root) {
				var list = [for (finding in row.findings) finding.kind];
				list.sort(Reflect.compare);
				return list.join(",");
			}
		throw "missing root " + root;
	}

	static function main():Void {
		var program = Frontend.compile(source);
		IrInliner.run(program, new IrInlineCache(), true);
		var before = [for (fn in program.functions) IrFunctionStateCodec.encode(fn)];
		var rows = IrAllocationReport.analyze(program, ["T.*"]);

		// Nothing to report: arithmetic, a scalar-replaced value class, an array loop, a map of references, recursion, an error message built only to throw.
		for (name in ["pure", "valueTemp", "arrIter", "mapExists", "mapGetRef", "rec", "guarded"])
			expect(kinds(rows, "T." + name) == "", name + " allocates nothing");

		expect(kinds(rows, "T.newObj") == "alloc", "an ordinary object is an allocation");
		expect(kinds(rows, "T.push") == "grow", "push allocates only when it grows");
		expect(kinds(rows, "T.setIdx") == "store", "an indexed store is not reported as growth");
		expect(kinds(rows, "T.mapGetInt") == "alloc", "a map of primitives boxes the value it returns");
		expect(kinds(rows, "T.mapIter") == "alloc", "iterating a map values snapshot allocates");
		expect(kinds(rows, "T.concat") == "alloc,alloc,alloc", "boxing, string conversion and concatenation");
		expect(kinds(rows, "T.closure") == "alloc,alloc,dynamic", "closure environment, closure and an unresolved call");

		// The finding is attributed to the callee, with the path that reaches it.
		var outer = rows.filter(row -> row.root == "T.outer")[0];
		expect(outer.findings.length == 1 && outer.findings[0].inFunction == "T.loopy", "callee allocation is found");
		expect(outer.findings[0].chain.join(">") == "T.outer>T.loopy", "chain names every call: " + outer.findings[0].chain.join(">"));
		expect(outer.findings[0].line > 0 && outer.findings[0].path != null, "findings carry a source location");

		// A method call reaches every override, and an interface call every implementor.
		var dispatch = rows.filter(row -> row.root == "T.dispatch")[0];
		expect(dispatch.findings.length == 1 && dispatch.findings[0].inFunction == "Heavy.f", "override is followed");
		var shape = rows.filter(row -> row.root == "T.viaInterface")[0];
		expect(shape.findings.length == 1 && shape.findings[0].inFunction == "Sq.area", "interface implementor is followed");

		// Roots: exact names, prefixes, and no match.
		expect(IrAllocationReport.analyze(program, ["T.pure"]).length == 1, "exact root");
		expect(IrAllocationReport.analyze(program, " T.pure , T.rec".split(",")).length == 2, "comma list ignores spaces");
		expect(IrAllocationReport.analyze(program, ["Nope.*"]).length == 0, "unmatched pattern");

		// Native classification.
		expect(IrAllocationReport.classifyNative("__math_sqrt") == null, "math is free");
		expect(IrAllocationReport.classifyNative("__array_pop_i32") == null, "pop does not allocate");
		expect(IrAllocationReport.classifyNative("__array_slice_ref").kind == "alloc", "slice copies");
		expect(IrAllocationReport.classifyNative("__map_string_ref_set").kind == "grow", "map set can grow");
		expect(IrAllocationReport.classifyNative("__map_string_ref_get") == null, "reference map get returns the stored reference");
		expect(IrAllocationReport.classifyNative("__sys_get_cwd").kind == "unknown", "unclassified natives are reported, not assumed free");

		for (i in 0...program.functions.length)
			expect(before[i].compare(IrFunctionStateCodec.encode(program.functions[i])) == 0, "the report does not change IR");
		Sys.println("PASS: allocation report follows calls, overrides and interfaces without changing IR");
	}
}
