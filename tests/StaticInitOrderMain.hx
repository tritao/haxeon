import compiler.hl.HlWriter;
import compiler.modules.Compiler;
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
		Sys.println("PASS: static initializers respect dependency order");
	}
}
