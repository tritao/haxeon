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
		compiler.update("StringBuf.hx", File.getContent("stdlib/StringBuf.hx"));
		compiler.update("haxe/ds/ArraySort.hx", File.getContent("stdlib/haxe/ds/ArraySort.hx"));
		compiler.update("haxe/ds/Option.hx", File.getContent("stdlib/haxe/ds/Option.hx"));
		compiler.update("haxe/ds/Either.hx", File.getContent("stdlib/haxe/ds/Either.hx"));
		compiler.update("Main.hx",
			"import haxe.ds.ArraySort; import haxe.ds.Option; import haxe.ds.Either; function compare(left:Int, right:Int):Int return left - right; function optionValue():Option<Int> return Some(20); function eitherValue():Either<Int,String> return Left(22); function readOption(value:Option<Int>):Int return switch value { case Some(number): number; case None: 0; }; function readEither(value:Either<Int,String>):Int return switch value { case Left(number): number; case Right(_): 0; }; function stringBufWorks():Bool { var buffer = new StringBuf(); buffer.add(\"A\"); buffer.add(1); buffer.addChar(66); buffer.addSub(\"cdef\", 1); buffer.addSub(\"XYZ\", 1, 1); return buffer.length == 7 && buffer.toString() == \"A1BdefY\"; } function main():Int { var values = [30, 10, 20, 20]; ArraySort.sort(values, compare); return stringBufWorks() ? values[0] + values[1] + values[2] - values[3] + readOption(optionValue()) + readEither(eitherValue()) - 20 : 0; }");
		File.saveBytes(output, HlWriter.encode(compiler.compile("Main").module));

		var invalid = new Compiler();
		RuntimeNatives.register(invalid);
		invalid.update("haxe/ds/Option.hx", File.getContent("stdlib/haxe/ds/Option.hx"));
		invalid.update("Main.hx", 'import haxe.ds.Option; function main():Int { var value:Option<Int> = Some("bad"); return 0; }');
		try {
			invalid.compile("Main");
			throw "generic enum accepted an invalid payload";
		} catch (_:CompileError) {}
	}
}
