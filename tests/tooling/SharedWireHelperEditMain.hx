import compiler.tools.CompilerArguments;
import compiler.tools.CompilerDriver;
import compiler.tools.CompilerSession;
import sys.FileSystem;
import sys.io.File;

/** Re-requesting one root codec must preserve shared nested codecs of retained roots. */
class SharedWireHelperEditMain {
	static function main():Void {
		var root = FileSystem.fullPath(".") + "/out/shared-wire-helper-edit-" + Std.random(0x3fffffff);
		FileSystem.createDirectory(root);
		var files = [
			"Inner.hx" => "@:wire typedef Inner = { @:id(1) var value:Int; };",
			"Left.hx" => "@:wire typedef Left = { @:id(1) var inner:Inner; };",
			"Right.hx" => "@:wire enum Right { @:id(1) Item(inner:Inner); }",
			"P.hx" =>
			"class P { public static function round(v:Left):Left return haxeon.wire.MessagePack.decode(haxeon.wire.MessagePack.encode(v)); public static function bump():Int return 0; }",
			"Q.hx" =>
			"class Q { public static function round(v:Right):Right return haxeon.wire.MessagePack.decode(haxeon.wire.MessagePack.encode(v)); public static function bump():Int return 0; }",
			"Main.hx" =>
			"class Main { public static function main():Int { var l:Left = {inner: {value: 21}}; var r:Right = Right.Item({value: 21}); var value = switch Q.round(r) { case Item(i): i.value; }; return P.round(l).inner.value + value + P.bump() + Q.bump(); } }"
		];
		var args = [
			"--target=hl",
			"--entry=Main",
			"--root=" + root,
			"--root=stdlib",
			"--output=" + root + "/main.hl"
		];
		var paths = [for (name in files.keys()) root + "/" + name];
		function build(session:CompilerSession, expected:Int):Void {
			CompilerDriver.compile(CompilerArguments.parse(args.concat(paths)), _ -> {}, session);
			var actual = Sys.command(".tools/hashlink/hl", [root + "/main.hl"]);
			if (actual != expected)
				throw 'Shared wire helper: expected $expected, got $actual';
		}
		for (codec in ["MessagePack", "JsonWire"]) {
			var codecFiles = [
				for (name => text in files)
					name => StringTools.replace(text, "MessagePack", codec)
			];
			for (edited in ["P.hx", "Q.hx"]) {
				for (name => text in codecFiles)
					File.saveContent(root + "/" + name, text);
				var session = new CompilerSession();
				build(session, 42);
				File.saveContent(root + "/" + edited, StringTools.replace(codecFiles.get(edited), "return 0;", "return 1;"));
				build(session, 43);
				var withoutCaller = StringTools.replace(codecFiles.get("Main.hx"), edited == "P.hx" ? "P.round(l).inner.value" : "switch Q.round(r)",
					edited == "P.hx" ? "21" : "switch r");
				withoutCaller = StringTools.replace(withoutCaller, edited == "P.hx" ? "P.bump()" : "Q.bump()", "0");
				File.saveContent(root + "/Main.hx", withoutCaller);
				build(session, 42);
				File.saveContent(root + "/Main.hx", codecFiles.get("Main.hx"));
				File.saveContent(root + "/" + edited,
					StringTools.replace(codecFiles.get(edited), "return haxeon.wire." + codec + ".decode(haxeon.wire." + codec + ".encode(v));", "return v;"));
				build(session, 42);
				File.saveContent(root + "/" + edited, codecFiles.get(edited));
				build(session, 42);
				File.saveContent(root + "/Inner.hx", StringTools.replace(codecFiles.get("Inner.hx"), "value:Int", "value:String"));
				var rejected = false;
				try {
					CompilerDriver.compile(CompilerArguments.parse(args.concat(paths)), _ -> {}, session);
				} catch (error:Dynamic) {
					if (Std.string(error).indexOf("Type mismatch") < 0)
						throw error;
					rejected = true;
				}
				if (!rejected)
					throw "Changed wire schema incorrectly accepted stale integer values";
				File.saveContent(root + "/Inner.hx", codecFiles.get("Inner.hx"));
				build(session, 42);
			}
		}
		for (name in FileSystem.readDirectory(root))
			FileSystem.deleteFile(root + "/" + name);
		FileSystem.deleteDirectory(root);
		Sys.println("PASS: shared nested wire codecs survive caller edits and removal/restoration");
	}
}
