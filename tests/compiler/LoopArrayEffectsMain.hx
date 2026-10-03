import compiler.Compiler;
import compiler.Diagnostic.CompileError;

/** Array storage operations cannot replace unrelated fields; user calls and callbacks can. */
class LoopArrayEffectsMain {
	static final prelude = 'class Box { public var entries:Array<Int> = [1, 2]; public function new() {} } '
		+ 'class FakeArray { public function new() {} public function push(view:View):Void { view.provider = null; } } '
		+ 'class View { public var provider:Null<Box>; var results:Array<Int> = []; var fake:FakeArray = new FakeArray(); '
		+ 'public function new() { provider = new Box(); } public function run():Int { ';

	static function source(body:String):String
		return prelude + body + ' } } function main():Int return new View().run();';

	static function check(label:String, body:String, accepted:Bool):Void {
		var compiler = new Compiler();
		compiler.addSourceRoot(Sys.getCwd() + "/stdlib");
		compiler.update("Main.hx", source(body));
		try {
			var compiled = compiler.compile("Main");
			if (accepted) {
				var expected = label == "inferred local array push" ? 3 : 2;
				var value = GeneratedProgramRunner.exitCode(compiled);
				if (value != expected)
					throw label + " returned " + value + " instead of " + expected;
			}
		} catch (error:CompileError) {
			if (!accepted && error.diagnostic.code == "E1005")
				return;
			throw label + ": " + error.diagnostic.format();
		}
		if (!accepted)
			throw label + " unexpectedly compiled";
	}

	static function main():Void {
		check("own array field push",
			'if (provider == null) return 0; for (i in 0...provider.entries.length) { var value = provider.entries[i]; results.push(value); } return results.length;',
			true);
		check("explicit own array field push",
			'if (provider == null) return 0; for (i in 0...provider.entries.length) { var value = provider.entries[i]; this.results.push(value); } return results.length;',
			true);
		check("local array push",
			'var output:Array<Int> = []; if (provider == null) return 0; for (i in 0...provider.entries.length) { output.push(provider.entries[i]); } return output.length;',
			true);
		check("inferred local array push",
			'var output = [0]; if (provider == null) return 0; for (i in 0...provider.entries.length) { output.push(provider.entries[i]); } return output.length;',
			true);
		check("user push can clear the field",
			'if (provider == null) return 0; for (i in 0...provider.entries.length) { var value = provider.entries[i]; fake.push(this); } return 0;', false);
		check("array callback can clear the field",
			'if (provider == null) return 0; for (i in 0...provider.entries.length) { var value = provider.entries[i]; results.sort(function(a:Int, b:Int):Int { provider = null; return 0; }); } return 0;',
			false);
		check("plain field assignment still invalidates",
			'if (provider == null) return 0; for (i in 0...provider.entries.length) { results.push(provider.entries[i]); provider = null; } return 0;', false);
		Sys.println("PASS: loop array effects preserve unrelated fields and reject real mutations");
	}
}
