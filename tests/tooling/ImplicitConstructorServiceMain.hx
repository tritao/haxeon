import compiler.service.LanguageService;

/** A constructor a class inherits is not written in its module, but editors still show and follow it. */
class ImplicitConstructorServiceMain {
	static function main():Void {
		var service = new LanguageService(),
			main = "function main():Int { var d = new Derived(40); return d.n + 2; }";
		service.update("Base.hx", "class Base { public var n:Int; public function new(n:Int) { this.n = n; } }");
		service.update("Derived.hx", "class Derived extends Base {}");
		service.update("Main.hx", main);
		service.compile("Main");
		var argument = main.indexOf("Derived(") + "Derived(".length,
			help = service.signatureHelp("Main.hx", argument);
		expect(help != null && help.label == "Derived(n:Int)", "signature help shows the inherited arguments, got " + (help == null ? "nothing" : help.label));
		expect(service.hover("Main.hx", main.indexOf("Derived") + 2) == "Derived(n:Int)", "hover on the class shows its constructor");
		var definition = service.definition("Main.hx", main.indexOf("Derived") + 2);
		expect(definition != null && definition.path == "Derived.hx", "the class is the definition of its inherited constructor");
		var names = [
			for (symbol in service.documentSymbols("Derived.hx"))
				symbol.name + ":" + symbol.kind
		];
		expect(names.join(",") == "Derived:class", "the module lists what it declares, not the synthesized constructor: " + names.join(","));
		expect(service.diagnostics("Derived.hx").length == 0 && service.diagnostics("Main.hx").length == 0, "no diagnostics");

		service.update("Base.hx", "class Base { public var n:Int; public function new(n:Int, k:Int = 0) { this.n = n + k; } }");
		service.compile("Main");
		var edited = service.signatureHelp("Main.hx", argument);
		expect(edited != null && edited.label == "Derived(n:Int, k:Int)", "editing the base constructor updates the derived signature");

		Sys.println("PASS: implicit constructors in the language service");
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
