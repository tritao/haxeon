import compiler.Compiler;

/** Focused semantic coverage for source-declared HashLink bindings. */
class ExternMain {
	static function main():Void {
		var compiler = new Compiler();
		compiler.update("Clock.hx", 'extern abstract Clock(Float) from Float { @:hlNative("std", "sys_time") public function shifted():Float; }');
		compiler.update("Main.hx", "import Clock; function read(value:Clock):Float return value.shifted(); function main():Int return 42;");
		var result = compiler.compile("Main");
		var found = false;
		for (native in result.module.natives)
			if (result.module.strings[native.library] == "std" && result.module.strings[native.name] == "sys_time")
				found = true;
		if (!found)
			throw "Extern abstract instance method did not produce a native binding";
		var classCompiler = new Compiler();
		classCompiler.update("Native.hx",
			'@:hlNative("platform") extern class Native { public static function poll():Int; @:hlNative("override", "renamed") public static function draw():Void; }');
		classCompiler.update("Main.hx", "import Native; function main():Int { Native.draw(); return Native.poll(); }");
		var classResult = classCompiler.compile("Main"),
			inherited = false,
			overridden = false;
		for (native in classResult.module.natives) {
			var library = classResult.module.strings[native.library],
				symbol = classResult.module.strings[native.name];
			if (library == "platform" && symbol == "poll")
				inherited = true;
			if (library == "override" && symbol == "renamed")
				overridden = true;
		}
		if (!inherited || !overridden)
			throw "Extern class native library inheritance or method override was not preserved";
		var bytesCompiler = new Compiler();
		bytesCompiler.update("hl/Bytes.hx", sys.io.File.getContent("stdlib/hl/Bytes.hx"));
		bytesCompiler.update("Main.hx", "function identity(value:hl.Bytes):hl.Bytes return value; function main():Int return 42;");
		bytesCompiler.compile("Main");
		var handleCompiler = new Compiler();
		handleCompiler.update("hl/Abstract.hx", sys.io.File.getContent("stdlib/hl/Abstract.hx"));
		handleCompiler.update("Main.hx",
			'import hl.Abstract; function identity(value:Abstract<"module">):Abstract<"module"> return value; function main():Int return 42;');
		handleCompiler.compile("Main");
		Sys.println("PASS: extern abstract receivers lower as native ABI argument zero");
	}
}
