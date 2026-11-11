import compiler.Compiler;
import compiler.hl.HlWriter;
import compiler.modules.ModulePath;

/** A tool outside the compiler's tree that links its sources: what an editor or build tool does (see docs/DEVELOPMENT.md). */
class ExternalToolMain {
	static function main():Void {
		var compiler = new Compiler();
		compiler.update("Main.hx", "function main():Int { return 42; }");
		var result = compiler.compile("Main");
		var bytes = HlWriter.encode(result.module).flatten();
		if (bytes.length == 0)
			throw "empty module";
		Sys.println("PASS: an external tool builds against the compiler sources through common.hxml (" + bytes.length + " bytes)");
	}
}
