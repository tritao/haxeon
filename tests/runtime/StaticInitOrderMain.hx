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
		Sys.println("PASS: static initializers respect dependency order");
	}
}
