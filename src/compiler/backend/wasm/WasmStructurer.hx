package compiler.backend.wasm;

import compiler.ir.IrFunction;

typedef WasmLoopInfo = {
	final header:Int;
	final body:Int;
	final exit:Int;
}

/** Finds reducible natural loops and merge points before Wasm emission. */
class WasmStructurer {
	public final functionName:String;
	public final analysis:WasmCfgAnalysis;
	public final loops:Map<Int, WasmLoopInfo> = [];

	public function new(fn:IrFunction) {
		functionName = fn.name;
		analysis = new WasmCfgAnalysis(fn);
		if (analysis.reducible)
			findLoops();
	}

	/** True when the CFG can be emitted with structured regions supported here. */
	public function canUseStructured():Bool {
		if (!analysis.reducible)
			return false;
		for (id in analysis.graph.order) {
			var successors = analysis.graph.successors.get(id);
			if (successors.length <= 1)
				continue;
			if (successors.length != 2 || successors[0] == successors[1])
				return false;
			if (loops.exists(id))
				continue;
			if (analysis.mergeFor(successors[0], successors[1]) == null)
				return false;
		}
		return true;
	}

	function findLoops():Void {
		var backSources:Map<Int, Array<Int>> = [];
		for (edge in analysis.backEdges()) {
			var sources = backSources.get(edge.to);
			if (sources == null) {
				sources = [];
				backSources.set(edge.to, sources);
			}
			sources.push(edge.from);
		}
		for (header in analysis.graph.order) {
			var successors = analysis.graph.successors.get(header);
			if (successors.length != 2)
				continue;
			var sources = backSources.get(header);
			if (sources == null)
				continue;
			var body:Null<Int> = null;
			for (successor in successors)
				for (source in sources)
					if (pathExists(successor, source, header))
						if (body == null)
							body = successor;
						else if (body != successor)
							body = null;
			if (body == null)
				continue;
			var exit = successors[0] == body ? successors[1] : successors[0];
			loops.set(header, {header: header, body: body, exit: exit});
		}
	}

	function pathExists(start:Int, target:Int, stop:Int):Bool {
		var work = [start], seen:Map<Int, Bool> = [];
		while (work.length > 0) {
			var current = work.pop();
			if (current == target)
				return true;
			if (current == stop || seen.exists(current))
				continue;
			seen.set(current, true);
			for (successor in analysis.graph.successors.get(current))
				work.push(successor);
		}
		return false;
	}
}
