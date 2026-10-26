import compiler.hl.HlWriter;
import compiler.Compiler;
import compiler.types.Type.CompilerType;
import sys.io.File;

/**
 * A literal is a String object created once when the module loads, not a new one at each evaluation. A live module holds
 * its literals the same way (a patch adds the global of a literal it introduces; LiveStringConstantsPatchMain runs that).
 */
class StringConstantsMain {
	static final source = 'function main():Int { var phase = "target"; var total = 0; var before = allocated(); '
		+ 'for (i in 0...1000) { if (phase == "target") total++; if (phase != "bubble") total++; } '
		+ 'var used = allocated() - before; return used < 1000.0 && total == 2000 ? 42 : 1; }';

	static function main():Void {
		var fixed = new Compiler();
		fixed.livePatching = false;
		fixed.registerNative("allocated", "std", "gc_total_allocated", [], CompilerType.TFloat);
		fixed.update("Main.hx", source);
		var fixedResult = fixed.compile("Main");
		if (fixedResult.module.constants.length < 2)
			throw 'A build nothing patches should hold each literal as a constant, got ${fixedResult.module.constants.length}';
		for (constant in fixedResult.module.constants)
			if (constant.fields.length != 2)
				throw "A String constant has two fields: its data and its length";
		var live = new Compiler();
		live.livePatching = true;
		live.registerNative("allocated", "std", "gc_total_allocated", [], CompilerType.TFloat);
		live.update("Main.hx", source);
		var liveResult = live.compile("Main");
		if (liveResult.module.constants.length != fixedResult.module.constants.length)
			throw 'A live module should hold the same ${fixedResult.module.constants.length} literal constants, got ${liveResult.module.constants.length}';
		File.saveBytes(Sys.args()[0], HlWriter.encode(fixedResult.module));
	}
}
