using compiler.compilation.BackendArtifact.BackendArtifacts;
import compiler.Compiler;
import compiler.Frontend;
import compiler.backend.Backend.BackendTarget;
import compiler.backend.wasm.WasmBackend;
import compiler.hl.HlWriter;
import compiler.hl.lower.HlLower;
import runtime.Runtime;
import sys.io.File;

class StaticInitOrderMain {
	static function main():Void {
		var compiler = new Compiler();
		compiler.update("Provider.hx", "class Provider { public static var value:Int = 40; }");
		compiler.update("Consumer.hx",
			"import Provider; class Consumer { public static var value:Int = Provider.value + 2; } function main():Int { return Consumer.value; }");
		var result = compiler.compile("Consumer"),
			live = Runtime.load(HlWriter.encode(result.artifact.hashLink().module).flatten(),
				result.artifact.hashLink().runtimeIdentity);
		var value = Runtime.callInt(live, result.artifact.hashLink().functionIds.get("main"));
		if (value != 42)
			throw "Static initializers did not run a provider before its consumer";
		Runtime.dispose(live);
		var fields:Array<String> = [];
		for (index in 0...80)
			fields.push('public static var value$index:Int = ' + (index == 0 ? '1' : 'value${index - 1} + 1') + ';');
		compiler = new Compiler();
		compiler.update("Main.hx",
			'class Chain { ${fields.join(" ")} } '
			+ 'class Colour { public final red:Int; public function new(red:Int) this.red = red; '
			+ 'public static function rgba(red:Int):Colour return new Colour(red); } '
			+ 'class Palette { public static final colour:Colour = Colour.rgba(2); } '
			+ 'function main():Int { return Chain.value79 + Palette.colour.red; }');
		var chunked = compiler.compile("Main");
		var helpers = [
			for (fn in chunked.ir.functions)
				if (StringTools.startsWith(fn.name, "__init$part")) fn
		];
		if (helpers.length < 10)
			throw "Static initialization was not split into bounded functions";
		live = Runtime.load(HlWriter.encode(chunked.artifact.hashLink().module).flatten(),
			chunked.artifact.hashLink().runtimeIdentity);
		if (Runtime.callInt(live, chunked.artifact.hashLink().functionIds.get("main")) != 82)
			throw "Static initializer order changed across chunks";
		Runtime.dispose(live);
		// A class runs after the classes its static initialization reaches, as in Haxe (StaticInitializationOrder); within a
		// class, initializers run in declaration order. tests/differential/static-init-order*.hx check the order against Haxe.
		var forward = ["a class declared later" => {
			source:"class A { public static final X:Int = B.X; } class B { public static final X:Int = 7; } function main():Int { return A.X; }",
				expected:7
		},
			"a field declared later in the same class reads its default" => {
			source:"class A { public static final X:Int = Y; public static final Y:Int = 7; } function main():Int { return A.X; }",
				expected:0
		},
			"a static read behind a call" => {
			source:"class A { public static final X:Int = B.get(); } class B { static final V:Int = 7; public static function get():Int return V; } "
				+ "function main():Int { return A.X; }",
				expected:7
		},
			"a static read behind an instance method is not followed" => {
			source:"class A { public static final X:Int = new B().get(); } class B { public function new() {} public function get():Int return C.V; } "
				+ "class C { public static final V:Int = 7; } function main():Int { return A.X; }",
				expected:0
		},
			"a cycle runs in the order the walk found" => {
			source:"class A { public static final X:Int = B.X + 7; } class B { public static final X:Int = A.X + 1; } function main():Int return A.X * 100 + B.X;",
				expected:801
		}];
		for (description => test in forward) {
			compiler = new Compiler();
			compiler.update("Main.hx", test.source);
			var ordered = compiler.compile("Main");
			live = Runtime.load(HlWriter.encode(ordered.artifact.hashLink().module).flatten(),
				ordered.artifact.hashLink().runtimeIdentity);
			var value = Runtime.callInt(live, ordered.artifact.hashLink().functionIds.get("main"));
			if (value != test.expected)
				throw 'Static initialization order differs from Haxe ($description): $value, expected ${test.expected}';
			Runtime.dispose(live);
		}
		// The stateless frontend uses the same assembler without the incremental function cache.
		var fullIr =
			Frontend.compile('class Seed { public static final value:Int = 0; } class Consumer { public static final values:Array<String> = ["All"].concat([for (value in Provider.values) value]); } class Provider { public static final values:Array<String> = ["Welding"]; } function main():Int return Consumer.values.length;');
		var full = runBytecode(SuiteOutput.path("static-init-full.hl"),
			HlWriter.encode(HlLower.lower(fullIr)).flatten());
		if (full.status != 2)
			throw "Stateless frontend initialized a consumer before its provider: " + full.output;
		// The first probe has no reads; later probes must not reuse its cached references.
		compiler = new Compiler();
		compiler.update("catalog/Category.hx",
			'package catalog; enum abstract Category(String) to String { var Welding = "Welding"; }');
		compiler.update("catalog/Catalog.hx",
			'package catalog; import catalog.Category; import browser.Browser; class Catalog { public static function seed():Int return Browser.seed; public static final categories:Array<Category> = [Welding]; }');
		compiler.update("browser/Browser.hx",
			'package browser; import catalog.Catalog; class Browser { public static final seed = 1; public static final categories:Array<String> = ["All"].concat([for (category in Catalog.categories) (category:String)]); }');
		compiler.update("Main.hx", 'import browser.Browser; function main():Int return Browser.categories.length;');
		for (incremental in [false, true]) {
			if (incremental)
				compiler.update("catalog/Catalog.hx",
					'package catalog; import catalog.Category; import browser.Browser; class Catalog { public static function seed():Int return Browser.seed; public static final categories:Array<Category> = [Welding, Welding]; }');
			var result = compiler.compile("Main");
			var writes:Array<String> = [];
			for (fn in result.ir.functions)
				if (StringTools.startsWith(fn.name, "__init$part"))
					for (block in fn.blocks)
						for (instruction in block.instructions)
							switch instruction.value {
								case GlobalSet(name, _):
									writes.push(name);
								case _:
							}
			if (writes.indexOf("catalog.Catalog.categories") < 0
				|| writes.indexOf("browser.Browser.categories") < 0
				|| writes.indexOf("catalog.Catalog.categories") > writes.indexOf("browser.Browser.categories"))
				throw 'Cross-module comprehension initialized before its provider (incremental=$incremental): $writes';
			live = Runtime.load(HlWriter.encode(result.artifact.hashLink().module).flatten(),
				result.artifact.hashLink().runtimeIdentity);
			if (Runtime.callInt(live, result.artifact.hashLink().functionIds.get("main")) != (incremental ? 3 : 2))
				throw "Cross-module comprehension produced the wrong categories";
			Runtime.dispose(live);
			for (target in [Wasm32, WasmGc]) {
				var bytes = new WasmBackend().compile(result.ir, {target: target, debugNames: true}).bytes;
				File.saveBytes(SuiteOutput.path('static-init-$target-' + (incremental ? "incremental" : "clean")
					+ ".wasm"), bytes);
			}
		}
		compiler = new Compiler();
		compiler.update("Main.hx",
			'class Missing { public static final values:Array<Int> = null; } class Consumer { public static final count:Int = Missing.values.length; } function main():Int return Consumer.count;');
		var nullResult = compiler.compile("Main");
		var failed = runBytecode(SuiteOutput.path("static-init-null.hl"),
			HlWriter.encode(nullResult.artifact.hashLink().module).flatten());
		if (failed.status == 0 || failed.output.indexOf('Cannot dereference null static "Missing.values"') < 0)
			throw "Null static dereference at startup did not report an error: " + failed.output;
		Sys.println("PASS: static initializers run in Haxe's order");
	}

	static function runBytecode(path:String, bytes:haxe.io.Bytes):{status:Int, output:String} {
		File.saveBytes(path, bytes);
		var child = new sys.io.Process(Sys.getEnv("HAXEON_HASHLINK_DIR") + "/hl", [path]);
		var output = child.stdout.readAll().toString() + child.stderr.readAll().toString(),
			status = child.exitCode();
		child.close();
		return {status: status, output: output};
	}
}
