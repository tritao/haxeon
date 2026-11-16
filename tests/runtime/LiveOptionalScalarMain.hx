using compiler.compilation.BackendArtifact.BackendArtifacts;
import compiler.CompileOptions;
import compiler.Compiler;
import compiler.hl.HlWriter;
import runtime.PatchSet;
import runtime.Runtime;

/** Scalar optional call clones must be refreshed when their source function changes. */
class LiveOptionalScalarMain {
	static function source(step:Int):String {
		return 'struct V { public var x:Int; public function new(x:Int) this.x = x; } '
			+ 'function adjust(value:Null<V>):Null<V> { if (value != null) value.x += $step; return value; } '
			+ 'function main():Int { var value:Null<V> = new V(40); var result = adjust(value); return result == null ? 0 : result.x; }';
	}
	static function main():Void {
		for (inlining in [false, true]) {
			var compiler = new Compiler();
			compiler.options = new CompileOptions({inlining: inlining});
			compiler.update("Main.hx", source(1));
			var first = compiler.compile("Main"),
				live = Runtime.load(HlWriter.encode(first.artifact.hashLink().module).flatten(),
					first.artifact.hashLink().runtimeIdentity),
				id = first.artifact.hashLink().functionIds.get("main");
			if (Runtime.callInt(live, id) != 41) throw "initial optional scalar call failed";
			compiler.update("Main.hx", source(2));
			var next = compiler.compile("Main");
			if (next.requiresReload
				|| next.artifact.hashLink().patchBytes == null)
				throw "editing an optional scalar call unexpectedly required a reload";
			Runtime.patchSet(live, new PatchSet(first.revision, next.revision, next.artifact.hashLink().patchBytes,
				next.changedFunctions));
			if (Runtime.callInt(live, id) != 42) throw "live optional scalar clone retained its old body";
			Runtime.dispose(live);
		}
		Sys.println("PASS: live scalar optional calls follow their edited functions with and without inlining");
	}
}
