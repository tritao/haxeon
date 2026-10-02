import compiler.hl.HlWriter;
import compiler.Compiler;
import runtime.Runtime;
import compiler.runtime.CompilerIntrinsics;

/**
 * Both string decode paths, plain literals and single-quoted literals with interpolation, read \xHH, \uHHHH,
 * \u{...}, three-digit octal and \' as Haxe does, and reject malformed ones at compile time.
 */
class StringEscapesMain {
	static function main():Void {
		// Each entry is a function body returning an Int, and the value it must produce.
		var cases:Array<{body:String, expected:Int}> = [
			{body: '"\\x41".charCodeAt(0)', expected: 65},
			{body: '"\\x7a\\x7A".charCodeAt(1)', expected: 122},
			{body: '"\\xe9".charCodeAt(0)', expected: 0xE9},
			{body: '"\\u0041".charCodeAt(0)', expected: 65},
			{body: '"\\u00e9".charCodeAt(0)', expected: 0xE9},
			{body: '"\\u20AC".charCodeAt(0)', expected: 0x20AC},
			{body: '"\\u{41}".charCodeAt(0)', expected: 65},
			{body: '"\\u{20AC}".charCodeAt(0)', expected: 0x20AC},
			{body: '"\\u{1F600}".length', expected: 2},
			{body: '"\\u{1F600}".charCodeAt(0)', expected: 0xD83D},
			{body: '"\\u{1F600}".charCodeAt(1)', expected: 0xDE00},
			{body: '"\\uD83D\\uDE00" == "\\u{1F600}" ? 1 : 0', expected: 1},
			{body: '"\\101".charCodeAt(0)', expected: 65},
			{body: '"\\377".charCodeAt(0)', expected: 255},
			{body: '"\\001x".length', expected: 2},
			{body: '"\\\'".charCodeAt(0)', expected: 39},
			{body: '"a\\"b".length', expected: 3},
			// Single-quoted with interpolation takes the second path.
			{body: "'\\x41${1}\\u{42}'.length", expected: 3},
			{body: "'\\x41${1}\\u{42}'.charCodeAt(2)", expected: 66},
			{body: "'\\101$$${2}'.charCodeAt(0)", expected: 65},
			{body: "'\\u00e9${3}\\'\\u{1F600}'.length", expected: 5},
			{body: "'\\377${1}'.charCodeAt(0)", expected: 255},
			{body: "'${4}\\uD83D\\uDE00' == '${4}\\u{1F600}' ? 1 : 0", expected: 1}
		];
		var source = "";
		for (index in 0...cases.length)
			source += 'function case$index():Int return ${cases[index].body};\n';
		source += "function main():Int return " + [for (index in 0...cases.length) 'case$index()'].join(" + ") + ";";
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot("stdlib");
		compiler.update("Main.hx", source);
		var result = compiler.compile("Main"),
			live = Runtime.load(HlWriter.encode(result.module), result.runtimeIdentity);
		for (index in 0...cases.length) {
			var actual = Runtime.callInt(live, result.functionIds.get('Main.case$index'));
			if (actual != cases[index].expected)
				throw '${cases[index].body} produced $actual, expected ${cases[index].expected}';
		}
		Runtime.dispose(live);

		var malformed = [
			'"\\x4"',
			'"\\xZZ"',
			'"\\u12"',
			'"\\u{}"',
			'"\\u{110000}"',
			'"\\u{1234567}"',
			'"\\uD800"',
			'"\\12"',
			'"\\x00"',
			'"\\u0000"',
			'"\\u{0}"',
			'"\\000"',
			"'\\x00${1}'",
			'"\\18x"',
			"'\\x4${1}'",
			"'\\u{zz}${1}'",
			"'${1}\\12'"
		];
		for (literal in malformed) {
			var rejected = false;
			try {
				var checker = new Compiler();
				checker.addSourceRoot("stdlib");
				checker.update("Main.hx", 'function main():Int { var s = $literal; return s.length; }');
				checker.compile("Main");
			} catch (error:Dynamic) {
				rejected = Std.string(error).indexOf("Invalid escape sequence") >= 0;
			}
			if (!rejected)
				throw 'The malformed escape in $literal was not rejected';
		}
		Sys.println("PASS: string escapes decode \\x, \\u, \\u{...}, octal and \\' in both literal forms");
	}
}
