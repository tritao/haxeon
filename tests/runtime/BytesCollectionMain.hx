using compiler.compilation.BackendArtifact.BackendArtifacts;
import compiler.Compiler;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;
import sys.io.File;

/**
	Bytes keep their data outside the heap, and the collector counts it: 256 MB of dropped 1 MB buffers, whose wrappers
	are a few kilobytes of heap, start a collection, and the data of the collected ones is no longer counted.
**/
class BytesCollectionMain {
	static function main():Void {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addStandardLibrarySourceRoot("stdlib");
		compiler.update("Main.hx",
			"import haxe.io.Bytes;\n"
			+ "function main():Int {\n"
			+ "  var before = hl.Gc.collections();\n"
			+ "  var kept = Bytes.alloc(1 << 20);\n"
			+ "  if (hl.Gc.externalBytes() < (1 << 20)) return 1;\n"
			+ "  for (i in 0...256) { var dropped = Bytes.alloc(1 << 20); dropped.set(0, i); }\n"
			+ "  if (hl.Gc.collections() == before) return 2;\n"
			+ "  hl.Gc.major(); hl.Gc.major();\n"
			+ "  var live = hl.Gc.externalBytes();\n"
			+ "  return live >= (1 << 20) && live < (8 << 20) && kept.length == (1 << 20) ? 42 : 3;\n"
			+ "}");
		File.saveBytes(Sys.args()[0], HlWriter.encode(compiler.compile("Main").artifact.hashLink().module).flatten());
	}
}
