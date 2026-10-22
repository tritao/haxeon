import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;
import compiler.hl.HlWriter;
import sys.io.File;

/** An abstract's type-only references must load source modules without help from its caller. */
class AbstractTypeDependencyMain {
	static function main():Void {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot("stdlib");
		var source = File.getContent("tests/programs/bytes-stream-float.hx");
		for (revision in 0...2) {
			compiler.update("Main.hx", revision == 0 ? source : StringTools.replace(source, "? 42 : 7", "? 43 : 7"));
			var result = compiler.compile("Main");
			execute(HlWriter.encode(result.module), revision == 0 ? 42 : 43);
		}
		// The entry imports only Api; Sibling appears solely in the abstract's signature.
		compiler = new Compiler();
		compiler.update("pkg/Sibling.hx", "package pkg; class Sibling { public var value:Int; public function new(value:Int) this.value=value; }");
		compiler.update("pkg/Api.hx",
			"package pkg; abstract Api(Int) { public function new() this=0; public function echo(value:Sibling):Sibling return value; }");
		// analyze the signature alone: do not rely on caller arguments to load Sibling.
		compiler.update("Main.hx", "import pkg.Api; function main():Int return 42;");
		compiler.compile("Main");
		compiler.update("pkg/Sibling.hx", "package pkg; class Sibling { public var changed:String; public function new() {} }");
		compiler.compile("Main");
		compiler = new Compiler();
		compiler.update("pkg/Storage.hx", "package pkg; class Storage { public function new() {} }");
		compiler.update("pkg/Underlying.hx", "package pkg; abstract Underlying(Storage) {}");
		compiler.update("Main.hx", "import pkg.Underlying; function main():Int return 42;");
		compiler.compile("Main");
		compiler = new Compiler();
		compiler.update("pkg/From.hx", "package pkg; abstract From(Int) from Int to Int {}");
		compiler.update("pkg/To.hx", "package pkg; abstract To(Int) from Int to Int {}");
		compiler.update("pkg/Conversions.hx", "package pkg; abstract Conversions(Int) from From to To {}");
		compiler.update("Main.hx", "import pkg.Conversions; function main():Int return 42;");
		compiler.compile("Main");
		compiler = new Compiler();
		compiler.update("pkg/Representation.hx", "package pkg; enum abstract Representation(Int) { var Zero=0; }");
		compiler.update("pkg/Mode.hx", "package pkg; enum abstract Mode(Representation) { var Zero=0; }");
		compiler.update("Main.hx", "import pkg.Mode; function main():Int return 42;");
		compiler.compile("Main");
		compiler = new Compiler();
		compiler.update("pkg/T.hx", "this is deliberately not valid source");
		compiler.update("pkg/U.hx", "this is deliberately not valid source either");
		compiler.update("pkg/Generic.hx", "package pkg; abstract Generic<T>(T) from T to T { public function identity<U>(value:U):U return value; }");
		compiler.update("Main.hx", "import pkg.Generic; function main():Int return 42;");
		compiler.compile("Main");
		Sys.println("PASS: abstract signature, underlying and conversion dependencies; stdlib siblings load without caller imports");
	}

	static function execute(bytes:haxe.io.Bytes, expected:Int):Void {
		var path = "out/abstract-type-dependency.hl";
		File.saveBytes(path, bytes);
		var child = new sys.io.Process(".tools/hashlink/hl", [path]);
		var output = child.stdout.readAll().toString() + child.stderr.readAll().toString(),
			code = child.exitCode();
		child.close();
		if (code != expected)
			throw 'Float stream returned $code, expected $expected: $output';
	}
}
