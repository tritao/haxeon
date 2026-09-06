import compiler.RuntimeAbi;
import compiler.hl.HlWriter;
import compiler.modules.Compiler;
import sys.io.File;

/** Compiles a program against the selectively vendored Haxe standard library. */
class StdlibMain {
	static function main():Void {
		var output = Sys.args()[0];
		var compiler = new Compiler();
		RuntimeAbi.register(compiler);
		compiler.update("haxe/ds/ArraySort.hx", File.getContent("stdlib/haxe/ds/ArraySort.hx"));
		compiler.update("haxe/ds/Option.hx", File.getContent("stdlib/haxe/ds/Option.hx"));
		compiler.update("haxe/ds/Either.hx", File.getContent("stdlib/haxe/ds/Either.hx"));
		compiler.update("Main.hx",
			"import haxe.ds.ArraySort; import haxe.ds.Option; import haxe.ds.Either; function compare(left:Int, right:Int):Int return left - right; function optionValue():Option<Int> return Some(20); function eitherValue():Either<Int,String> return Left(22); function readOption(value:Option<Int>):Int return switch value { case Some(_): 10; case None: 0; }; function readEither(value:Either<Int,String>):Int return switch value { case Left(_): 12; case Right(_): 0; }; function main():Int { var values = [30, 10, 20, 20]; ArraySort.sort(values, compare); return values[0] + values[1] + values[2] - values[3] + readOption(optionValue()) + readEither(eitherValue()); }");
		File.saveBytes(output, HlWriter.encode(compiler.compile("Main").module));
	}
}
