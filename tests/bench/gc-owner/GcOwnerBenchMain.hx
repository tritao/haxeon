import compiler.Compiler;
import compiler.hl.HlWriter;
import runtime.Runtime;

private extern class GcStats {
	@:hlNative("std", "gc_collections") static function collections():Float;
	@:hlNative("std", "gc_mark_micros") static function markMicros():Float;
	@:hlNative("std", "gc_max_pause_micros") static function maxPauseMicros():Float;
	@:hlNative("std", "gc_total_allocated") static function totalAllocated():Float;
}

/**
	Allocation-heavy loop with a realistic live set, run once as ordinary program code (unowned allocations) and once
	as a patchable module (every allocation is owned by the module). Prints GC pauses and allocation throughput.

	usage: hl GcOwnerBenchMain.hl [iterations] [liveNodes]
**/
class GcOwnerBenchMain {
	// Keep in step with `moduleSource`: the same loop, compiled by the Haxe compiler instead of Haxeon.
	static function bench(iterations:Int, liveNodes:Int):Int {
		var live = new Array<Node>();
		for (i in 0...liveNodes) {
			var node = new Node(i);
			node.payload = [i, i + 1];
			live.push(node);
		}
		var sum = 0;
		for (i in 0...iterations) {
			var slot = ((i & 0x3FFFFF) * 31) % liveNodes;
			var temp = new Node(i);
			temp.next = live[slot];
			sum += temp.next.value & 1;
			if (i % 8 == 0) {
				var fresh = new Node(i);
				fresh.payload = [i, i + 1];
				live[slot] = fresh;
			}
		}
		return sum + live.length;
	}

	static final moduleSource = "class Node { public var next:Node; public var value:Int; public var tag:Int; public var payload:Array<Int>; public function new(value:Int) { this.value = value; } }
function bench(iterations:Int, liveNodes:Int):Int {
	var live = new Array<Node>();
	for (i in 0...liveNodes) {
		var node = new Node(i);
		node.payload = [i, i + 1];
		live.push(node);
	}
	var sum = 0;
	for (i in 0...iterations) {
		var slot = ((i & 0x3FFFFF) * 31) % liveNodes;
		var temp = new Node(i);
		temp.next = live[slot];
		sum += temp.next.value & 1;
		if (i % 8 == 0) {
			var fresh = new Node(i);
			fresh.payload = [i, i + 1];
			live[slot] = fresh;
		}
	}
	return sum + live.length;
}
function iterations():Int { return ITER; }
function liveNodes():Int { return LIVE; }
function run():Int { return bench(ITER, LIVE); }
function main():Int { return 0; }";

	static function report(label:String, seconds:Float, iterations:Int, c0:Float, m0:Float, a0:Float) {
		var collections = GcStats.collections() - c0;
		var markMs = (GcStats.markMicros() - m0) / 1000.0;
		var allocated = (GcStats.totalAllocated() - a0) / (1024.0 * 1024.0);
		Sys.println(label
			+ ': ${Math.round(seconds * 1000)} ms, ${Math.round(iterations * 1.125 / seconds / 1e5) / 10} M allocs/s, ${Std.int(collections)} collections, '
			+ 'mean pause ${Math.round(markMs / Math.max(collections, 1) * 100) / 100} ms, max pause ${Math.round(GcStats.maxPauseMicros() / 10) / 100} ms, '
			+ '${Math.round(allocated)} MB allocated');
	}

	static function main() {
		var args = Sys.args();
		var iterations = args.length > 0 ? Std.parseInt(args[0]) : 20000000;
		var liveNodes = args.length > 1 ? Std.parseInt(args[1]) : 300000;
		var mode = args.length > 2 ? args[2] : "both";
		if (mode != "module") {
			var c0 = GcStats.collections(),
				m0 = GcStats.markMicros(),
				a0 = GcStats.totalAllocated();
			var t0 = haxe.Timer.stamp();
			var result = bench(iterations, liveNodes);
			report("unowned (program code)", haxe.Timer.stamp() - t0, iterations, c0, m0, a0);
			Sys.println('  result $result');
		}
		if (mode != "program") {
			var compiler = new Compiler();
			compiler.update("Main.hx", StringTools.replace(StringTools.replace(moduleSource, "ITER", Std.string(iterations)), "LIVE", Std.string(liveNodes)));
			var compiled = compiler.compile("Main");
			var module = Runtime.load(HlWriter.encode(compiled.module), compiled.runtimeIdentity);
			var run = compiled.functionIds.get("Main.run");
			var c0 = GcStats.collections(),
				m0 = GcStats.markMicros(),
				a0 = GcStats.totalAllocated();
			var t0 = haxe.Timer.stamp();
			var result = Runtime.callInt(module, run);
			report("owned (patchable module)", haxe.Timer.stamp() - t0, iterations, c0, m0, a0);
			Sys.println('  result $result');
			Runtime.dispose(module);
		}
	}
}

class Node {
	public var next:Node;
	public var value:Int;
	public var tag:Int;
	public var payload:Array<Int>;

	public function new(value:Int) {
		this.value = value;
	}
}
