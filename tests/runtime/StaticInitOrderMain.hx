import compiler.hl.HlWriter;
import compiler.Compiler;
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
			"a static read behind a method call" =>
			"class A { public static final X:Int = new B().get(); } class B { public function new() {} public function get():Int return C.V; } " +
			"class C { public static final V:Int = 7; } function main():Int { return A.X; }",
			"a dependency cycle" =>
			"class A { public static final X:Int = B.X + 7; } class B { public static final X:Int = A.X + 1; } function main():Int { return 7; }"
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
		Sys.println("PASS: static initializers respect dependency order");
	}
}
