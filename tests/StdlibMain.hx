import compiler.runtime.RuntimeNatives;
import compiler.hl.HlWriter;
import compiler.Compiler;
import compiler.Diagnostic.CompileError;
import sys.io.File;

/** Compiles a program against the selectively vendored Haxe standard library. */
class StdlibMain {
	static function main():Void {
		var output = Sys.args()[0];
		var compiler = new Compiler();
		RuntimeNatives.register(compiler);
		compiler.addSourceRoot("stdlib");
		compiler.update("Main.hx",
			"import haxe.ds.ArraySort; import haxe.ds.Option; import haxe.ds.Either; function compare(left:Int, right:Int):Int return left - right; function optionValue():Option<Int> return Some(20); function eitherValue():Either<Int,String> return Left(22); function readOption(value:Option<Int>):Int return switch value { case Some(number): number; case None: 0; }; function readEither(value:Either<Int,String>):Int return switch value { case Left(number): number; case Right(_): 0; }; function stdlibWorks():Bool { var buffer = new StringBuf(); buffer.add(\"A\"); buffer.add(1); buffer.addChar(66); buffer.addSub(\"cdef\", 1); buffer.addSub(\"XYZ\", 1, 1); var random = Std.random(10); return buffer.length == 7 && buffer.toString() == \"A1BdefY\" && StringTools.contains(\"abc\", \"b\") && StringTools.startsWith(\"abc\", \"ab\") && StringTools.endsWith(\"abc\", \"bc\") && StringTools.replace(\"a-b-a\", \"a\", \"x\") == \"x-b-x\" && StringTools.ltrim(\"  x\") == \"x\" && StringTools.rtrim(\"x \\t\") == \"x\" && StringTools.rtrim(\" \\n\") == \"\" && StringTools.trim(\" x \") == \"x\" && StringTools.lpad(\"x\", \"0\", 3) == \"00x\" && StringTools.lpad(\"x\", \"ab\", 4) == \"ababx\" && StringTools.lpad(\"abc\", \"0\", 2) == \"abc\" && StringTools.lpad(\"x\", \"\", 3) == \"x\" && StringTools.rpad(\"x\", \"0\", 3) == \"x00\" && StringTools.rpad(\"x\", \"ab\", 4) == \"xabab\" && StringTools.rpad(\"abc\", \"0\", 2) == \"abc\" && StringTools.rpad(\"x\", \"\", 3) == \"x\" && StringTools.hex(0) == \"0\" && StringTools.hex(42) == \"2A\" && StringTools.hex(42, 4) == \"002A\" && StringTools.hex(-1) == \"FFFFFFFF\" && StringTools.isSpace(\" x\", 0) && !StringTools.isSpace(\"\", 0) && !StringTools.isSpace(\"x\", -1) && !StringTools.isSpace(\"x\", 1) && Std.parseInt(\"42\") == 42 && Std.parseInt(\"-7\") == -7 && Std.parseInt(\"0x2A\") == 42 && Std.parseInt(\"12tail\") == 12 && Std.parseInt(\"bad\") == 0 && Std.parseFloat(\"3.5\") == 3.5 && Std.parseFloat(\"-2.25\") == -2.25 && Std.int(3.9) == 3 && Std.int(-3.9) == -3 && Std.int(7) == 7 && Std.string(42) == \"42\" && Std.random(0) == 0 && Std.random(1) == 0 && random >= 0 && random < 10; } function main():Int { var values = [30, 10, 20, 20]; ArraySort.sort(values, compare); return stdlibWorks() ? values[0] + values[1] + values[2] - values[3] + readOption(optionValue()) + readEither(eitherValue()) - 20 : 0; }");
		if (compiler.modules.exists("StringBuf") || compiler.modules.exists("haxe.ds.ArraySort"))
			throw "stdlib modules were loaded eagerly";
		var result = compiler.compile("Main");
		for (native in compiler.nativeConfiguration())
			if (native.name == "Std.parseInt" || native.name == "Std.parseFloat" || native.name == "Std.random" || native.name == "Std.string")
				throw 'public Std native "${native.name}" remained in the host registry';
		for (module in [
			"Std",
			"StringBuf",
			"StringTools",
			"haxe.ds.ArraySort",
			"haxe.ds.Option",
			"haxe.ds.Either"
		])
			if (!compiler.modules.exists(module))
				throw 'stdlib module "$module" was not discovered';
		if (compiler.compile("Main").retyped.length != 0)
			throw "unchanged stdlib modules were not cached";
		var stringToolsSymbols:Map<String, Bool> = [
			"__string_starts_with" => true,
			"__string_ends_with" => true,
			"__string_replace" => true,
			"__string_ltrim" => true,
			"__string_trim" => true,
			"__string_is_space" => true
		];
		var stdSymbols:Map<String, Bool> = [
			"__std_parse_int" => true,
			"__std_parse_float" => true,
			"__std_random" => true,
			"__std_string" => true
		];
		for (native in result.module.natives) {
			var symbol = result.module.strings[native.name];
			stringToolsSymbols.remove(symbol);
			stdSymbols.remove(symbol);
		}
		for (symbol in stringToolsSymbols.keys())
			throw 'StringTools source binding "$symbol" was not emitted';
		for (symbol in stdSymbols.keys())
			throw 'Std source binding "$symbol" was not emitted';
		File.saveBytes(output, HlWriter.encode(result.module));

		var invalid = new Compiler();
		RuntimeNatives.register(invalid);
		invalid.addSourceRoot("stdlib");
		invalid.update("Main.hx", 'import haxe.ds.Option; function main():Int { var value:Option<Int> = Some("bad"); return 0; }');
		try {
			invalid.compile("Main");
			throw "generic enum accepted an invalid payload";
		} catch (_:CompileError) {}

		var missing = new Compiler();
		RuntimeNatives.register(missing);
		missing.addSourceRoot("stdlib");
		missing.update("Main.hx", "import haxe.ds.Missing; function main():Int return 0;");
		try {
			missing.compile("Main");
			throw "missing stdlib import compiled";
		} catch (error:CompileError) {
			if (error.diagnostic.code != "E2001")
				throw error;
		}
	}
}
