import compiler.service.LanguageService;

/** A member without a comment of its own is documented, on hover, by the member it overrides or implements. */
class InheritedDocumentationServiceMain {
	static function main():Void {
		var service = new LanguageService(),
			main = "function main():Int { var shape = new Square(); var special = new Special(); "
				+ "return shape.area() + special.area() + special.sides(); }";
		service.update("Shape.hx", "interface Shape {\n\t/** The area, in square units. */\n\tfunction area():Int;\n}");
		service.update("Square.hx", "class Square implements Shape {\n\tpublic function new() {}\n"
			+ "\tpublic function area():Int return 4;\n\t/** How many sides. */\n\tpublic function sides():Int return 4;\n}");
		service.update("Special.hx", "class Special extends Square {\n\toverride public function area():Int return 9;\n"
			+ "\t/** Its own count. */\n\toverride public function sides():Int return 5;\n}");
		service.update("Main.hx", main);
		service.compile("Main");
		expect(markdown(service, main, "shape.area") == "The area, in square units.",
			"an implementation shows the interface's comment");
		expect(markdown(service, main, "special.area") == "The area, in square units.",
			"an override of an implementation shows the comment from further up");
		expect(markdown(service, main, "special.sides") == "Its own count.",
			"a comment of the member's own comes first");
		Sys.println("PASS: inherited documentation in the language service");
	}

	static function markdown(service:LanguageService, source:String, call:String):String {
		var documentation = service.hoverDocumentation("Main.hx", source.indexOf(call) + call.indexOf(".") + 2);
		return documentation == null ? "(none)" : StringTools.trim(documentation.markdown);
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
