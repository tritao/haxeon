import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;
import compiler.hl.HlWriter;

class SourceRevisionDeterminismMain {
	static function create(source:String):Compiler {
		var c = new Compiler();
		CompilerIntrinsics.register(c);
		c.addStandardLibrarySourceRoot("stdlib");
		c.livePatching = false;
		c.developmentMetadata = true;
		c.update("Main.hx", source);
		return c;
	}

	static function main():Void {
		var cases = [
			"function main():Int { return 42; }",
			"class Main { static var cached:Int=42; static function main():Int return cached; }",
			"class Box { public var n:Int=42; public function new() {} } function main():Int return new Box().n;",
			"function wrap<T>(v:T):Int {var f=()->42;return f();} function main():Int return wrap(1);",
			"class Main { static function wrap<T>(v:T):Int {var f=()->42;return f();} static function main():Int return wrap(1); }",
			"class Constants { public static var x:Int=42; } function main():Int return Constants.x;",
			"function compute(value:Int=42):Int return value; function main():Int return compute();",
			"class Main { static function compute(value:Int=42):Int return value; static function main():Int return compute(); }",
			"struct Value implements Equatable { public var n:Int; public function new(n:Int) this.n=n; } function main():Int return new Value(1)==new Value(1)?42:1;",
			"class Main { static var values:Array<Int>=[42]; static function main():Int return values[0]; }",
			"inline function calc(n:Int):Int {" + [for (i in 0...30) "n=n+1;"].join("") + "return n;} function main():Int return calc(12);",
			"class Main { static inline function calc(n:Int):Int {" + [for (i in 0...30) "n=n+1;"].join("") +
				"return n;} static function main():Int return calc(12); }"
		];
		for (source in cases) {
			for (edited in [source + "\n// comment\n", " " + source, "\n" + source]) {
				var incremental = create(source);
				incremental.compile("Main");
				incremental.update("Main.hx", edited);
				var warm = HlWriter.encode(incremental.compile("Main").module);
				var cold = HlWriter.encode(create(edited).compile("Main").module);
				if (warm.compare(cold) != 0)
					throw 'Source metadata differs after editing case ${cases.indexOf(source)}: $edited';
			}
		}
		for (caller in [
			"function call():Int return Defaults.read();",
			"function call():Int {var f=()->Defaults.read();return f();}",
			"function call():Int {var f=()->{var g=()->Defaults.read();return g();};return f();}",
			"function call():Int return new Defaults().read();",
			"function wrap<T>(x:T):Int return Defaults.read(); function call():Int return wrap(0);",
			"function call():Int return new Defaults().value;"
		]) {
			var defaults = caller.indexOf(".value") >= 0 ? "class Defaults {public var value:Int; public function new(n:Int=42) value=n;}" : caller.indexOf("new Defaults") >= 0 ? "class Defaults {public function new() {} public function read(n:Int=42):Int return n;}" : "class Defaults {public static function read(n:Int=42):Int return n;}";
			for (edited in [defaults + "\n// comment\n", " " + defaults, "\n" + defaults]) {
				function program(text:String):Compiler {
					var c = create("function main():Int return Caller.call()+Explicit.call();");
					c.update("Explicit.hx", "function call():Int return 0;");
					c.update("Caller.hx", caller);
					c.update("Defaults.hx", text);
					return c;
				}
				var incremental = program(defaults);
				incremental.compile("Main");
				incremental.update("Defaults.hx", edited);
				var result = incremental.compile("Main");
				if (result.retyped.indexOf("Explicit.call") >= 0)
					throw "Unrelated caller was invalidated";
				var warm = HlWriter.encode(result.module);
				var cold = HlWriter.encode(program(edited).compile("Main").module);
				if (warm.compare(cold) != 0)
					throw "Cross-module default source metadata differs: " + caller;
			}
		}

		var source = new compiler.Source.SourceFile("Defaults.hx", "original");
		var state = new compiler.modules.ModuleState("Caller", source);
		state.defaultArgumentSources.set("call", ["Defaults.hx" => source]);
		state.copy().defaultArgumentSources.get("call").remove("Defaults.hx");
		if (!state.defaultArgumentSources.get("call").exists("Defaults.hx"))
			throw "Transaction copy mutated source dependencies";

		Sys.println("PASS: initializer and default argument provenance matches cold compilation after source edits");
	}
}
