import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;

/**
 * A program's output depends only on what it reaches (docs/FRONTEND_RESTART.md): adding a module nothing calls, one that itself calls `Reflect`,
 * must not change how the program's enums are stored or any function of the program. Built plain (the early prune runs), once without the module
 * and once with it as a root module.
 */
class UnusedModuleInvarianceMain {
	static final unused = "class UnusedReflect { public static function peek(object:Dynamic):Dynamic return Reflect.field(object, \"x\"); "
		+ "public static function poke(object:Dynamic):Void Reflect.setField(object, \"x\", 1); }";

	static function build(withModule:Bool):compiler.Compiler.CompileResult {
		var c = new Compiler(null, CompilerIntrinsics.configuration());
		c.livePatching = false;
		c.addStandardLibrarySourceRoot("stdlib");
		c.configure("invariance-" + withModule, "invariance", compiler.tools.CompilerDriver.targetDefines("hl"));
		c.update("Main.hx", sys.io.File.getContent("tests/programs/closure-method-value-arguments.hx"));
		if (withModule) {
			c.update("UnusedReflect.hx", unused);
			c.addRootModule("UnusedReflect");
		}
		return c.compile("Main");
	}

	static function storage(result:compiler.Compiler.CompileResult):String
		return [
			for (declaration in result.ir.enums)
				declaration.name + "=" + (declaration.inlineStorage != null)
		].join(",");

	static function main():Void {
		var without = build(false), with = build(true);
		if (storage(without) != storage(with))
			throw 'An unused module changed the enum storage: [${storage(without)}] against [${storage(with)}]';
		if (storage(without).indexOf("CallbackValue=true") < 0)
			throw 'The program no longer has an inline CallbackValue (${storage(without)}); the test needs one that an unused module could flip';
		// The program: the same functions, each with the same IR.
		var left = [for (fn in without.ir.functions) fn.name => fn],
			right = [for (fn in with.ir.functions) fn.name => fn];
		for (name => fn in left) {
			var other = right.get(name);
			if (other == null)
				throw 'The function "$name" is gone when an unused module is present';
			if (!compiler.ir.codec.IrFunctionStateEquality.same(fn, other))
				throw 'The function "$name" changed when an unused module is present';
		}
		for (name in right.keys())
			if (!left.exists(name))
				throw 'The function "$name" appears only when an unused module is present';
		// The HashLink module: a plain build writes the natives, classes and globals the reached program uses, so it is the same bytes.
		var bytesWithout = compiler.hl.HlWriter.encode(without.module).flatten(),
			bytesWith = compiler.hl.HlWriter.encode(with.module).flatten();
		if (bytesWithout.compare(bytesWith) != 0) {
			var at = 0, limit = Std.int(Math.min(bytesWithout.length, bytesWith.length));
			while (at < limit && bytesWithout.get(at) == bytesWith.get(at))
				at++;
			throw 'An unused module changed the HashLink module: ${bytesWithout.length} against ${bytesWith.length} bytes, first difference at $at';
		}
		Sys.println("PASS: an unused module that calls Reflect changes neither the enum storage, nor any function, nor the bytes of the HashLink module");
	}
}
