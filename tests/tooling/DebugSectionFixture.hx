import compiler.Frontend;
import compiler.Source.SourceFile;
import compiler.hl.HlWriter;
import compiler.ir.hl.HlLower;
import haxe.io.Bytes;
import sys.io.File;

class DebugSectionFixture {
	static function main():Void {
		var args = Sys.args();
		if (args.length != 2)
			throw "Expected valid and malformed output paths";
		var program = Frontend.compileFile(new SourceFile("debug-section-fixture.hx", "function main():Int return 0;\n"));
		var code = HlLower.lower(program);
		code.debugSections.push({
			kind: 0x3FFF,
			version: 9,
			flags: 0,
			payload: Bytes.ofString("unknown-section")
		});
		var encoded = HlWriter.encode(code);
		File.saveBytes(args[0], encoded);
		File.saveBytes(args[1], encoded.sub(0, encoded.length - 1));
	}
}
