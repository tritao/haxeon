import compiler.Compiler;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;
import sys.io.File;

/** Verifies that managed byte views alias their source without copying. */
class BytesViewMain {
	static function main():Void {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot("stdlib");
		compiler.update("Main.hx",
			'import haxe.io.Bytes; function main():Int { var source = Bytes.alloc(4); source.set(0, 10); source.set(1, 20); var view = Bytes.view(source, 1, 2); view.set(0, 42); return view.length == 2 && source.get(1) == 42 && source.get(2) == 0 ? 42 : 1; }');
		File.saveBytes(Sys.args()[0], HlWriter.encode(compiler.compile("Main").module));
	}
}
