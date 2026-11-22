import compiler.CompileOptions;
import compiler.Compiler;
import compiler.ir.model.Ir;
import project.PackageManifest;

class InlineConfigurationMain {
	static function expect(ok:Bool, message:String):Void {
		if (!ok)
			throw message;
	}

	static function helperCalls(compiler:Compiler):Int {
		var result = compiler.compile("Main", null, false), count = 0;
		for (fn in result.ir.functions)
			if (fn.name == "Main.main")
				for (block in fn.blocks)
					for (located in block.instructions)
						switch located.value {
							case Call(_, callTarget, _) if (callTarget.name == "Main.helper"):
								count++;
							default:
						}
		return count;
	}

	static function main():Void {
		var base = '{"version":1,"package":{"name":"test"},"entry":"Main"';
		expect(PackageManifest.parse("test/haxeon.json", base + '}').inlineEnabled == null,
			"inherit omitted inline setting");
		expect(PackageManifest.parse("test/haxeon.json", base + ',"inline":false}').inlineEnabled == false,
			"parse inline false");
		expect(PackageManifest.parse("test/haxeon.json", base + ',"inline":true}').inlineEnabled == true,
			"parse inline true");
		var rejected = false;
		try
			PackageManifest.parse("test/haxeon.json", base + ',"inline":"false"}')
		catch (_:Dynamic)
			rejected = true;
		expect(rejected, "reject nonboolean inline setting");
		var source =
			'class Main { static inline function helper(x:Int):Int { return x + 1; } public static function main():Int { return helper(41); } }';
		var first = new Compiler(),
			second = new Compiler();
		first.update("Main.hx", source);
		second.update("Main.hx", source);
		first.options = new CompileOptions({inlining: false});
		second.options = new CompileOptions({inlining: true});
		expect(helperCalls(first) == 1, "disabled compiler retains function for breakpoints");
		expect(helperCalls(second) == 0, "enabled compiler still inlines");
		expect(helperCalls(first) == 1, "another compiler cannot change this compiler's choice");
		first.options = new CompileOptions({inlining: true});
		expect(helperCalls(first) == 0, "memo invalidation after changing choice");
		first.options = new CompileOptions({inlining: false});
		expect(helperCalls(first) == 1, "restore uninlined published IR");
		var flags = CompileOptions.fromArguments(["--no-inline", "--check-reuse"]);
		expect(!flags.inlining && flags.checkReuse && flags.loadStoreForwarding
			&& flags.arguments().join(" ") == "--no-inline --check-reuse",
			"options read from and written as flags");
		Sys.println("PASS: inline options are per compiler, invalidate cached IR, and round-trip as flags");
	}
}
