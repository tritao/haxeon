import compiler.Compiler;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;
import sys.io.File;

/** Compiles JSON parsing and printing against the native-target standard library. */
class JsonMain {
	static function main():Void {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot("stdlib");
		compiler.update("Main.hx",
			"import haxe.Json; function main():Int {\n"
			+ "  var encoded = Json.stringify({ text: 'Olá 😀', number: 40, ok: true, items: [1, 2] });\n"
			+ "  var value:Dynamic = Json.parse(encoded);\n"
			+ "  var items:Array<Dynamic> = cast(Reflect.field(value, 'items'), Array<Dynamic>);\n"
			+ "  if (Reflect.field(value, 'text') != 'Olá 😀' || Reflect.field(value, 'number') != 40 || Reflect.field(value, 'ok') != true) return 1;\n"
			+ "  if (items.length != 2 || items[0] != 1 || items[1] != 2) return 2;\n"
			+ "  var escaped:Dynamic = Json.parse('{\\\"value\\\":\\\"line\\\\n\\\\u263A\\\"}');\n"
			+ "  if (Reflect.field(escaped, 'value') != 'line\\n☺') return 3;\n"
			+ "  var rejected = false; try Json.parse('{bad') catch (_:Dynamic) rejected = true;\n"
			+ "  return rejected ? 42 : 4;\n"
			+ "}");
		File.saveBytes(Sys.args()[0], HlWriter.encode(compiler.compile("Main").module));
	}
}
