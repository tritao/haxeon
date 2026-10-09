import compiler.Diagnostic.CompileError;
import compiler.Source.SourceFile;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.types.Typer;

class StructSyntaxMain {
	static function main():Void {
		var source = "package demo;\n"
			+ "struct Pair<T:Portable> : Component, Serializable<T> {\n"
			+ "  public var x:Int;\n"
			+ "  public function new(x:Int) this.x = x;\n"
			+ "}\n",
			file = new SourceFile("Struct.hx", source),
			program = new Parser(new Lexer(file).tokenize()).parseProgram();
		if (program.classes.length != 1)
			throw "struct syntax did not produce a nominal declaration";
		var declaration = program.classes[0],
			structStart = source.indexOf("struct Pair"),
			structEnd = source.lastIndexOf("}") + 1;
		if (declaration.isStruct != true
			|| declaration.name != "Pair"
			|| declaration.span.start != structStart
			|| declaration.span.end != structEnd)
			throw "struct declaration did not preserve its identity and full source span";
		if (declaration.typeParameters.length != 1 || declaration.interfaces.length != 2 || declaration.base != null)
			throw "struct generic parameters or colon interface list were parsed incorrectly";
		if (source.substring(declaration.fields[0].span.start, declaration.fields[0].span.end).indexOf("x:Int") < 0)
			throw "struct field source span did not cover its declaration";

		expectError("struct Point extends Base {}", "cannot extend a class", "extends");
		expectError("struct Point implements Located {}", 'with ":"', "implements");
		expectError("extern struct Point {}", "cannot be declared extern", "struct");
		expectError("struct Point { public var x; }", "requires a type or initializer", ";");
		expectError("struct { public var x:Int; }", "Expected Identifier", "{");
		expectTypingError("struct Generic<T> { public var value:T; } function main():Int return 0;", 'Generic struct "Generic" is not supported yet');
		expectTypingError('@:repr("C") struct Point { public var x:Int; } function main():Int return 0;', 'does not use @:repr');
		expectTypingError("interface HasX { function xValue():Int; } struct Missing : HasX { public var value:Int; } function main():Int return 0;",
			'does not implement "HasX.xValue"');
		expectTypingError("interface HasX { function xValue():Int; } struct Missing { public function xValue():Int return 42; } "
			+ "function read<T:HasX>(value:T):Int return value.xValue(); function main():Int return read(new Missing());",
			'does not satisfy constraint "interface:HasX');
		expectTypingError("interface HasX { function xValue():Int; } struct Point : HasX { public function xValue():Int return 42; } "
			+ "function take(value:HasX):Int return value.xValue(); function main():Int return take(new Point());",
			"Type mismatch for argument 1 to \"take\"");
		Sys.println("PASS: struct declarations retain spans and report malformed forms");
	}

	static function expectError(source:String, fragment:String, marker:String):Void {
		try {
			new Parser(new Lexer(new SourceFile("InvalidStruct.hx", source)).tokenize()).parseProgram();
			throw 'expected a diagnostic containing "$fragment"';
		} catch (error:CompileError) {
			if (error.diagnostic.message.indexOf(fragment) < 0)
				throw 'expected "$fragment", got "${error.diagnostic.message}"';
			var expectedStart = source.indexOf(marker);
			if (error.diagnostic.span.start != expectedStart)
				throw 'expected diagnostic at $expectedStart, got ${error.diagnostic.span.start}';
		}
	}

	static function expectTypingError(source:String, fragment:String):Void {
		try {
			Typer.typeLibrary(new Parser(new Lexer(new SourceFile("InvalidStruct.hx", source)).tokenize()).parseProgram());
			throw 'expected a type diagnostic containing "$fragment"';
		} catch (error:CompileError) {
			if (error.diagnostic.message.indexOf(fragment) < 0)
				throw 'expected "$fragment", got "${error.diagnostic.message}"';
		}
	}
}
