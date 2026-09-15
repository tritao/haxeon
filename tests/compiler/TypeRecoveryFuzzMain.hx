import compiler.Source.SourceFile;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.types.Typer;

/** Checks that ordinary editor mutations still produce a partial typed program. */
class TypeRecoveryFuzzMain {
	static function main():Void {
		var source = "class Box { public var value:Int; public function read(scale:Int):Int { if (scale > 0) return value * scale; return 0; } } function helper(value:Int):Int return value; function main():Int { var box:Box = new Box(); var values = [1, 2]; var callback = (item:Int) -> item + 1; box.value; return switch (values[0]) { case 1: callback(helper(41)); default: box.read(1); }; }",
			fragments = [";", ")", "}", ",", ".", ":", "=", "(", "[", "?"];
		for (caseIndex in 0...72) {
			var position = (caseIndex * 37 + 11) % source.length,
				width = 1 + caseIndex % 3,
				end = Std.int(Math.min(source.length, position + width)),
				mutated = switch caseIndex % 3 {
					case 0: source.substring(0, position) + source.substring(end);
					case 1: source.substring(0, position) + fragments[caseIndex % fragments.length] + source.substring(position);
					default: source.substring(0, position) + fragments[caseIndex % fragments.length] + source.substring(end);
				};
			var recovered = new Parser(new Lexer(new SourceFile("TypeRecovery.hx", mutated)).tokenize()).parseProgramRecovering().program,
				typed = Typer.typeRecovered(recovered);
			if (typed == null)
				throw 'tolerant typing abandoned mutation $caseIndex at source offset $position';
		}
		for (end in 0...source.length + 1) {
			var truncated = source.substring(0, end),
				recovered = new Parser(new Lexer(new SourceFile("TypeRecoveryTruncated.hx", truncated)).tokenize()).parseProgramRecovering().program,
				diagnostics = [],
				typed = Typer.typeRecovered(recovered, null, null, diagnostics);
			if (typed == null)
				throw 'tolerant typing abandoned truncation at source offset $end: ${[for (diagnostic in diagnostics) diagnostic.message].join(" | ")}';
		}
		Sys.println("PASS: tolerant typing retained all deterministic mutations");
	}
}
