import compiler.Source.SourceFile;
import compiler.service.ImportOrder;
import compiler.service.UnusedImports.ImportTarget;
import compiler.syntax.Ast.AstProgram;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;

class ImportOrderMain {
	static final modules:Map<String, AstProgram> = [
		"kit.Shapes" => parse("Shapes.hx", "package kit; class Circle { public function new() {} } class Square { public function new() {} }"),
		"other.Circle" => parse("Circle.hx", "package other; class Circle { public function new() {} }")
	];

	static function parse(name:String, text:String):AstProgram
		return new Parser(new Lexer(new SourceFile(name, text)).tokenize()).parseProgram();

	static function resolve(path:String):Null<ImportTarget> {
		var parts = path.split(".");
		for (count in 0...parts.length) {
			var module = parts.slice(0, parts.length - count).join(".");
			if (modules.exists(module))
				return {program: modules.get(module), member: count == 0 ? null : parts[parts.length - count]};
		}
		return null;
	}

	static function sorted(text:String):String
		return ImportOrder.sort(text, ImportOrder.tokens("subject.hx", text), resolve);

	static function unsafe(text:String):Array<String>
		return [
			for (block in ImportOrder.find(text, ImportOrder.tokens("subject.hx", text), resolve))
				if (block.unsafe != null) block.unsafe
		];

	static function expect(actual:String, wanted:String, label:String):Void {
		if (actual != wanted)
			throw '$label: expected\n$wanted\nfound\n$actual';
		Sys.println('PASS: $label');
	}

	static function main():Void {
		var tail = "\nfunction main() {}\n";
		expect(sorted("import a.B;\nimport a.C;" + tail), "import a.B;\nimport a.C;" + tail, "a sorted run is left alone");
		expect(sorted("package p;\n\nimport b.Z;\nimport a.Y;\nimport a.X;" + tail), "package p;\n\nimport a.X;\nimport a.Y;\nimport b.Z;" + tail,
			"a run is sorted by path");
		expect(sorted("import compiler.ffi.HxiAbi;\nimport compiler.Diagnostic;" + tail), "import compiler.Diagnostic;\nimport compiler.ffi.HxiAbi;" + tail,
			"paths compare as ASCII, so a type sorts before a subpackage");
		expect(sorted("import b.B;\nimport a.A;\n\nimport d.D;\nimport c.C;" + tail), "import a.A;\nimport b.B;\n\nimport c.C;\nimport d.D;" + tail,
			"a blank line separates runs, each sorted on its own");
		expect(sorted("import b.B;\n// tools\nimport a.A;" + tail), "import b.B;\n// tools\nimport a.A;" + tail, "a comment ends a run");
		expect(sorted("import b.B;\n#if hl\nimport a.A;\n#end" + tail), "import b.B;\n#if hl\nimport a.A;\n#end" + tail, "a directive ends a run");
		expect(sorted("import b.B; var x = 1;\nimport a.A;" + tail), "import b.B; var x = 1;\nimport a.A;" + tail,
			"an import that shares its line with code is not moved");
		expect(sorted("import b.Thing as Other;\nimport a.Thing;" + tail), "import a.Thing;\nimport b.Thing as Other;" + tail,
			"an alias moves with its import and binds its own name");
		expect(sorted("import z.Point;\nimport y.Point;" + tail), "import z.Point;\nimport y.Point;" + tail, "two imports of one name keep their order");
		if (unsafe("import z.Point;\nimport y.Point;" + tail).join("") != "Point is imported by both z.Point and y.Point")
			throw "the reason names both imports";
		expect(sorted("import other.Circle;\nimport kit.Shapes;" + tail), "import other.Circle;\nimport kit.Shapes;" + tail,
			"a module import binds every type it declares");
		expect(sorted("import other.Circle;\nimport kit.Shapes.Square;" + tail), "import kit.Shapes.Square;\nimport other.Circle;" + tail,
			"a member import binds only its member");
		expect(sorted("import kit.*;\nimport a.A;" + tail), "import kit.*;\nimport a.A;" + tail, "a package wildcard is never sorted");
		expect(sorted("import kit.Shapes.*;\nimport a.A;" + tail), "import a.A;\nimport kit.Shapes.*;" + tail,
			"a module wildcard binds the module's names and can be sorted");
		Sys.println("PASS: import order");
	}
}
