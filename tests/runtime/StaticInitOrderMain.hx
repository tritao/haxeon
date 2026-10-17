import compiler.hl.HlWriter;
import compiler.Compiler;
import compiler.Frontend;
import compiler.ir.hl.HlLower;
import compiler.backend.wasm.WasmBackend;
import compiler.backend.Backend.BackendTarget;
import sys.io.File;
import runtime.Runtime;

class StaticInitOrderMain {
	static function main():Void {
		var compiler = new Compiler();
		compiler.update("Provider.hx", "class Provider { public static var value:Int = 40; }");
		compiler.update("Consumer.hx",
			"import Provider; class Consumer { public static var value:Int = Provider.value + 2; } function main():Int { return Consumer.value; }");
		var result = compiler.compile("Consumer"),
			live = Runtime.load(HlWriter.encode(result.module), result.runtimeIdentity);
		var value = Runtime.callInt(live, result.functionIds.get("main"));
		if (value != 42)
			throw "Static initializers did not respect module dependency order";
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
		live = Runtime.load(HlWriter.encode(chunked.module), chunked.runtimeIdentity);
		if (Runtime.callInt(live, chunked.functionIds.get("main")) != 82)
			throw "Static initializer order changed across chunks";
		Runtime.dispose(live);
		// A dependency declared later in the same module, in the same class, or behind a call still runs first.
		var forward = [
			"a class declared later" =>
			"class A { public static final X:Int = B.X; } class B { public static final X:Int = 7; } function main():Int { return A.X; }",
			"a field declared later in the same class" =>
			"class A { public static final X:Int = Y; public static final Y:Int = 7; } function main():Int { return A.X; }",
			"a static read behind a call" =>
			"class A { public static final X:Int = B.get(); } class B { static final V:Int = 7; public static function get():Int return V; } " +
			"function main():Int { return A.X; }",
			"a stored callback is not an initializer dependency" =>
			"class A { public static final callback:()->Int = () -> B.value; } class B { public static final value:Int = A.callback == null ? 0 : 7; } function main():Int { var callback = A.callback; return callback(); }",
			"a deferred callback passed through a recursive helper" =>
			"class A { public static final value:Int = store(() -> B.value, 0) + 7; static function store(f:()->Int, depth:Int):Int return depth <= 0 ? 0 : store(f, depth - 1); } class B { public static final value:Int = A.value; } function main():Int return B.value;",
			"a callback read from a static field and invoked at startup" =>
			"class Seed { public static final value:Int = 0; } class A { public static final callback:()->Int = () -> B.value; public static final value:Int = invoke(); static function invoke():Int { var f = callback; return f(); } } class B { public static final value:Int = 7; } function main():Int return A.value;",
			"a returned callback invoked at startup" =>
			"class Seed { public static final value:Int = 0; } class A { public static final value:Int = factory()(); static function factory():()->Int return () -> B.value; } class B { public static final value:Int = 7; } function main():Int return A.value;",
			"an immediately invoked closure" =>
			"class Seed { public static final value:Int = 0; } class A { public static final value:Int = (() -> B.value)(); } class B { public static final value:Int = 7; } function main():Int return A.value;",
			"an invoked callback argument" =>
			"class Seed { public static final value:Int = 0; } class A { public static final value:Int = apply(() -> B.value); static function apply(f:()->Int):Int return forward(f); static function forward(f:()->Int):Int return f(); } class B { public static final value:Int = 7; } function main():Int return A.value;",
			"a callback invoked through a constructor field" =>
			"class Seed { public static final value:Int = 0; } class Holder { var callback:()->Int; public var value:Int; public function new(f:()->Int) { callback = f; var action = callback; value = action(); } } class A { public static final value:Holder = new Holder(() -> B.value); } class B { public static final value:Int = 7; } function main():Int return A.value.value;",
			"unrelated methods with the same name are not dependencies" =>
			"class A { public static final value:Int = new B().get(); } class B { public function new() {} public function get():Int return 7; } class Unrelated { public function new() {} public function get():Int return A.value; } function main():Int { new Unrelated(); return A.value; }",
			"overriding methods can read static dependencies" =>
			"class Seed { public static final value:Int = 0; } class A { public static final value:Int = read(new Child()); static function read(base:Base):Int return base.get(); } class Base { public function new() {} public function get():Int return 0; } class Child extends Base { public function new() { super(); } public override function get():Int return Provider.value; } class Provider { public static final value:Int = 7; } function main():Int return A.value;",
			"a static read behind a method call" =>
			"class A { public static final X:Int = new B().get(); } class B { public function new() {} public function get():Int return C.V; } " +
			"class C { public static final V:Int = 7; } function main():Int { return A.X; }"
		];
		for (description => source in forward) {
			compiler = new Compiler();
			compiler.update("Main.hx", source);
			var ordered = compiler.compile("Main");
			live = Runtime.load(HlWriter.encode(ordered.module), ordered.runtimeIdentity);
			if (Runtime.callInt(live, ordered.functionIds.get("main")) != 7)
				throw 'Static initializers ran before their dependency: $description';
			Runtime.dispose(live);
		}
		// The stateless frontend uses the same assembler without the incremental function cache.
		var fullIr = Frontend.compile('class Seed { public static final value:Int = 0; } class Consumer { public static final values:Array<String> = ["All"].concat([for (value in Provider.values) value]); } class Provider { public static final values:Array<String> = ["Welding"]; } function main():Int return Consumer.values.length;');
		var full = runBytecode("out/static-init-full.hl", HlWriter.encode(HlLower.lower(fullIr)));
		if (full.status != 2)
			throw "Stateless frontend initialized a consumer before its provider: " + full.output;
		// The first probe has no reads; later probes must not reuse its cached references.
		compiler = new Compiler();
		compiler.update("catalog/Category.hx", 'package catalog; enum abstract Category(String) { var Welding = "Welding"; }');
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
			live = Runtime.load(HlWriter.encode(result.module), result.runtimeIdentity);
			if (Runtime.callInt(live, result.functionIds.get("main")) != (incremental ? 3 : 2))
				throw "Cross-module comprehension produced the wrong categories";
			Runtime.dispose(live);
			for (target in [Wasm32, WasmGc]) {
				var bytes = new WasmBackend().compile(result.ir, {target: target, debugNames: true}).bytes;
				File.saveBytes('out/static-init-$target-' + (incremental ? "incremental" : "clean") + ".wasm", bytes);
			}
		}
		for (source in [
			"class A { public static final X:Int = B.X + 7; } class B { public static final X:Int = A.X + 1; } function main():Int return 0;",
			"class A { public static final X:Int = X + 1; } function main():Int return 0;",
			"class A { static final callback:()->Int = () -> X; public static final X:Int = invoke(); static function invoke():Int { var f = callback; return f(); } } function main():Int return 0;"
		]) {
			compiler = new Compiler();
			compiler.update("Main.hx", source);
			var rejected = false;
			try
				compiler.compile("Main")
			catch (error:compiler.Diagnostic.CompileError) {
				if (error.diagnostic.code != "E_STATIC_INIT_CYCLE" || error.diagnostic.message.indexOf("A.X ->") < 0)
					throw error;
				rejected = true;
			}
			if (!rejected)
				throw "Static initializer cycle was accepted";
		}
		compiler = new Compiler();
		compiler.update("Main.hx",
			'class Missing { public static final values:Array<Int> = null; } class Consumer { public static final count:Int = Missing.values.length; } function main():Int return Consumer.count;');
		var nullResult = compiler.compile("Main");
		var failed = runBytecode("out/static-init-null.hl", HlWriter.encode(nullResult.module));
		if (failed.status == 0 || failed.output.indexOf('Cannot dereference null static "Missing.values"') < 0)
			throw "Null static dereference at startup did not report an error: " + failed.output;
		Sys.println("PASS: static initializers respect dependency order");
	}

	static function runBytecode(path:String, bytes:haxe.io.Bytes):{status:Int, output:String} {
		File.saveBytes(path, bytes);
		var child = new sys.io.Process(".tools/hashlink/hl", [path]);
		var output = child.stdout.readAll().toString() + child.stderr.readAll().toString(),
			status = child.exitCode();
		child.close();
		return {status: status, output: output};
	}
}
