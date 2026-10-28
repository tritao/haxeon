import compiler.Source.SourceFile;
import compiler.service.UnusedImports;
import compiler.service.UnusedImports.ImportTarget;
import compiler.syntax.Ast.AstProgram;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;

class UnusedImportsMain {
	static function parse(name:String, text:String):AstProgram
		return new Parser(new Lexer(new SourceFile(name, text)).tokenize()).parseProgram();

	static function unused(modules:Map<String, AstProgram>, text:String):Array<String> {
		var tokens = new Lexer(new SourceFile("subject.hx", text)).tokenize();
		function resolve(path:String):Null<ImportTarget> {
			var parts = path.split(".");
			for (count in 0...parts.length) {
				var module = parts.slice(0, parts.length - count).join(".");
				if (modules.exists(module))
					return {program: modules.get(module), member: count == 0 ? null : parts[parts.length - count]};
			}
			return null;
		}
		return [for (item in UnusedImports.find(tokens, resolve)) item.path];
	}

	static function expect(actual:Array<String>, wanted:Array<String>, label:String):Void {
		if (actual.join(",") != wanted.join(","))
			throw '$label: expected [${wanted.join(", ")}], found [${actual.join(", ")}]';
		Sys.println('PASS: $label');
	}

	static function main():Void {
		var modules:Map<String, AstProgram> = [
			"kit.Shapes" => parse("Shapes.hx", "package kit; class Circle { public function new() {} } class Square { public function new() {} }"),
			"kit.Flavour" => parse("Flavour.hx", "package kit; enum Flavour { Klipper; Marlin; }"),
			"kit.Meters" => parse("Meters.hx", "package kit; abstract Meters(Float) from Float to Float { }"),
			"kit.Plain" => parse("Plain.hx", "package kit; abstract Plain(Float) { }"),
			"kit.Alias" => parse("Alias.hx", "package kit; typedef Alias = kit.Flavour;"),
			"kit.Records" => parse("Records.hx", "package kit; typedef Point = {x:Float, y:Float}; typedef Line = {a:Point, b:Point};")
		];
		expect(unused(modules, "package app; import kit.Shapes; function main() {}"), ["kit.Shapes"], "an import nothing mentions is unused");
		expect(unused(modules, "package app; import kit.Shapes; function main() { var c = new Circle(); }"), [], "a type of the module counts");
		expect(unused(modules, "package app; import kit.Shapes.Square; function main() { var c = new Circle(); }"), ["kit.Shapes.Square"],
			"a module-member import needs its own type");
		expect(unused(modules, "package app; import kit.Flavour; function main() { var f = [Klipper, Marlin]; }"), [],
			"an enum import is used through its constructors");
		expect(unused(modules, "package app; import kit.Flavour; function main() {}"), ["kit.Flavour"], "an unused enum import is reported");
		expect(unused(modules, "package app; import kit.Meters; function main() { var f:Float = 1.0; }"), [], "an abstract with conversions is never judged");
		expect(unused(modules, "package app; import kit.Plain; function main() {}"), ["kit.Plain"], "an abstract without conversions is judged");
		expect(unused(modules, "package app; import kit.Alias; function main() {}"), [], "an alias of a named type is never judged");
		expect(unused(modules, "package app; import kit.Records; function main() {}"), ["kit.Records"], "a structure alias is judged");
		expect(unused(modules, "package app; import kit.Shapes; function main() { var s = 'a ${Circle}'; }"), [], "string interpolation counts");
		expect(unused(modules, "package app; import kit.Shapes.*; function main() {}"), [], "a wildcard is never judged");
		expect(unused(modules, "package app; import kit.Missing; function main() {}"), [], "an unresolved module is never judged");
		expect(unused(modules, "package app; import kit.Shapes as S; function main() { new S.Circle(); }"), [], "an alias counts when mentioned");
		expect(unused(modules, "package app; import kit.Shapes as S; function main() { new Circle(); }"), ["kit.Shapes"], "the original name does not count behind an alias");
		Sys.println("PASS: unused import analysis");
	}
}
