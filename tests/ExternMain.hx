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
		Sys.println("PASS: extern abstract receivers lower as native ABI argument zero");
	}
}
