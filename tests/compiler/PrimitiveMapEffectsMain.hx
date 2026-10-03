import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;
import compiler.Diagnostic.CompileError;

class PrimitiveMapEffectsMain {
	static final support = 'class Support { public static var view:View; var flags:Map<String,Bool> = ["x"=>true]; '
		+ 'public function new() {} public function has(key:String):Bool return flags.exists(key); }';
	static final mainSource = 'class Box { public var value:Int = 7; public function new() {} } '
		+ 'class View { public var provider:Null<Box>; var support:Support = new Support(); '
		+ 'public function new() { provider = new Box(); Support.view = this; } '
		+ 'public function run():Int { if (provider == null) return 0; if (support.has("x")) return provider.value; return 0; } } '
		+ 'function main():Int return new View().run();';

	static function compiler(source:String):Compiler {
		var result = new Compiler(null, CompilerIntrinsics.configuration());
		result.addSourceRoot(Sys.getCwd() + "/stdlib");
		result.update("Support.hx", source);
		result.update("Main.hx", mainSource);
		return result;
	}

	static function rejected(result:Compiler):Bool {
		try
			result.compile("Main")
		catch (error:CompileError) {
			if (error.diagnostic.code != "E1005")
				throw error;
			return true;
		}
		return false;
	}

	static function loops():Void {
		var source = 'class Box { public var value:Int = 7; public function new() {} } '
			+ 'class View { public static var current:View; public var provider:Null<Box>; public function new() { provider = new Box(); current = this; } '
			+ 'public function run(flags:Map<String,Bool>):Int { if (provider == null) return 0; var total = 0; '
			+ 'for (i in 0...2) if (flags.exists("x")) total += provider.value; return total; } } '
			+ 'function main():Int return new View().run(["x"=>true]);';
		var result = new Compiler(null, CompilerIntrinsics.configuration());
		result.addSourceRoot(Sys.getCwd() + "/stdlib");
		result.update("Main.hx", source);
		if (GeneratedProgramRunner.exitCode(result.compile("Main")) != 14)
			throw "loop lost a fact across a typed map read";
		var fake = 'class FakeMap { public function new() {} public function exists(key:String):Bool { View.current.provider = null; return true; } } ';
		result.update("Main.hx",
			fake + StringTools.replace(source, 'for (i in 0...2) if (flags.exists("x")) total += provider.value;',
				'for (i in 0...2) { var flags:FakeMap = new FakeMap(); if (flags.exists("x")) total += provider.value; }'));
		if (!rejected(result))
			throw "shadowed map parameter was still treated as a primitive map";
		result.update("Main.hx",
			fake + StringTools.replace(source, 'for (i in 0...2) if (flags.exists("x")) total += provider.value;',
				'for (flags in [new FakeMap(), new FakeMap()]) { total += provider.value; flags.exists("x"); }'));
		if (!rejected(result))
			throw "loop variable inherited the outer map's effect classification";
		result.update("Main.hx",
			fake + StringTools.replace(source, 'for (i in 0...2) if (flags.exists("x")) total += provider.value;',
				'var values = [for (flags in [new FakeMap(), new FakeMap()]) { var value = provider.value; flags.exists("x"); value; }]; total = values[0];'));
		if (!rejected(result))
			throw "comprehension variable inherited the outer map's effect classification";
		result.update("Main.hx",
			fake + StringTools.replace(source, 'for (i in 0...2) if (flags.exists("x")) total += provider.value;',
				'var values = [for (flags in [new FakeMap(), new FakeMap()]) "x" => { var value = provider.value; flags.exists("x"); value; }];'));
		if (!rejected(result))
			throw "map comprehension variable inherited the outer map's effect classification";
		result.update("Main.hx",
			StringTools.replace(source, 'for (i in 0...2) if (flags.exists("x")) total += provider.value;',
				'var values = [for (i in 0...2) if (flags.exists("x")) provider.value]; total = values[0] + values[1];'));
		if (GeneratedProgramRunner.exitCode(result.compile("Main")) != 14)
			throw "comprehension lost a fact across an unshadowed primitive map read";
		var fakeArray = StringTools.replace(StringTools.replace(fake, "FakeMap", "FakeArray"), "exists(key:String):Bool", "push(key:Int):Bool");
		var arraySource = StringTools.replace(StringTools.replace(source, "flags:Map<String,Bool>", "flags:Array<Int>"), '["x"=>true]', '[1]');
		result.update("Main.hx",
			fakeArray + StringTools.replace(arraySource, 'for (i in 0...2) if (flags.exists("x")) total += provider.value;',
				'for (flags in [new FakeArray(), new FakeArray()]) { total += provider.value; flags.push(1); }'));
		if (!rejected(result))
			throw "loop variable inherited the outer array's effect classification";
		result.update("Main.hx",
			fakeArray + StringTools.replace(arraySource, 'for (i in 0...2) if (flags.exists("x")) total += provider.value;',
				'var values = [for (flags in [new FakeArray(), new FakeArray()]) { var value = provider.value; flags.push(1); value; }];'));
		if (!rejected(result))
			throw "comprehension variable inherited the outer array's effect classification";
	}

	static function main():Void {
		loops();
		for (body in [
			"return this.flags.exists(key);",
			"{ var local:Map<String,Bool> = flags; return local.exists(key); }",
			'{ var local = ["x"=>true]; var alias = local; return alias.exists(key); }',
			"return flags.get(key) == true;",
			"return flags.size() > 0;",
			"{ flags.keys(); flags.values(); return true; }",
			"{ var ints:Map<Int,Bool> = [1=>true]; return ints.exists(1); }"
		]) {
			var candidate = compiler(StringTools.replace(support, "return flags.exists(key);", body));
			if (GeneratedProgramRunner.exitCode(candidate.compile("Main")) != 7)
				throw "primitive map read variant failed";
		}
		var parameterHelper = StringTools.replace(support, "public function new()",
			"public static function lookup(values:Map<String,Bool>, key:String):Bool return values.exists(key); public function new()");
		parameterHelper = StringTools.replace(parameterHelper, "return flags.exists(key);", "return Support.lookup(flags, key);");
		if (GeneratedProgramRunner.exitCode(compiler(parameterHelper).compile("Main")) != 7)
			throw "typed map argument effects failed";
		var result = compiler(support);
		if (GeneratedProgramRunner.exitCode(result.compile("Main")) != 7)
			throw "wrong primitive map helper result";
		var impure = StringTools.replace(support, "return flags.exists(key);", "{ view.provider = null; return flags.exists(key); }");
		result.update("Support.hx", impure);
		if (!rejected(result) || !rejected(compiler(impure)))
			throw "map helper mutation retained a field fact";
		result.update("Support.hx", support);
		if (GeneratedProgramRunner.exitCode(result.compile("Main")) != 7)
			throw "restored map helper failed";
		var fake = 'class FakeMap { public function new() {} public function exists(key:String):Bool { Support.view.provider = null; return true; } } '
			+ StringTools.replace(support, 'Map<String,Bool> = ["x"=>true]', 'FakeMap = new FakeMap()');
		if (!rejected(compiler(fake)))
			throw "user-defined exists was assumed to be a map read";
		Sys.println("PASS: primitive map read effects, runtime, user-method rejection and incremental invalidation");
	}
}
