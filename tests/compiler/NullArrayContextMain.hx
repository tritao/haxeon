import compiler.Compiler;
import compiler.Diagnostic.CompileError;

class NullArrayContextMain {
	static final prefix = 'class Box { public var value:Int = 7; public function new() {} } '
		+ 'class Holder { public var values:Array<Null<Box>>; public function new(values:Array<Null<Box>>) { this.values = values; } } ';

	static function compiler(body:String):Compiler {
		var compiler = new Compiler();
		compiler.addSourceRoot(Sys.getCwd() + "/stdlib");
		compiler.update("Main.hx",
			prefix
			+ 'function make():Holder { '
			+ body
			+ ' } '
			+ 'function main():Int { var holder = make(); holder.values[0] = new Box(); var box = holder.values[0]; return box == null ? 0 : box.value; }');
		return compiler;
	}

	static function incremental():Void {
		var result = compiler('var values = [null]; return new Holder(values);');
		result.compile("Main");
		var changed = StringTools.replace(prefix, "Array<Null<Box>>", "Array<Null<String>>");
		// Changing the constructor's contract must also recheck the old caller's writes.
		var source = changed
			+ 'function make():Holder { var values = [null]; values.push(new Box()); return new Holder(values); } '
			+ 'function main():Int return 0;';
		result.update("Main.hx", source);
		var fresh = new Compiler();
		fresh.addSourceRoot(Sys.getCwd() + "/stdlib");
		fresh.update("Main.hx", source);
		for (candidate in [result, fresh]) {
			var rejected = false;
			try
				candidate.compile("Main")
			catch (error:CompileError) {
				if (error.diagnostic.code != "E1002")
					throw error;
				rejected = true;
			}
			if (!rejected)
				throw "constructor edit retained an incompatible element type";
		}
	}

	static function main():Void {
		for (initializer in ['[null]', '[for (_ in 0...2) null]']) {
			var result = compiler('var values = ' + initializer + '; var alias = values; return new Holder(alias);').compile("Main");
			if (GeneratedProgramRunner.exitCode(result) != 7)
				throw "nullable array storage failed";
		}
		try {
			compiler('var values = [null]; values.push(1); return new Holder(values);').compile("Main");
		} catch (error:CompileError) {
			if (error.diagnostic.code != "E1009" && error.diagnostic.code != "E1003" && error.diagnostic.code != "E1002")
				throw error;
			incremental();
			Sys.println("PASS: null array constructor context, aliasing, runtime, rejection, and incremental edits");
			return;
		}
		throw "incompatible array mutation accepted";
	}
}
