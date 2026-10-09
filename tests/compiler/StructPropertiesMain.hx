import compiler.Diagnostic.CompileError;
import compiler.Source.SourceFile;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.types.Typer;

class StructPropertiesMain {
	static function main():Void {
		expectSuccess("abstract RawPtr<T>(hl.Bytes) {}\n"
			+ "@:flat struct Address { public var pointer:RawPtr<Int>; }\n"
			+ "interface PortableRecord extends Portable {}\n"
			+ "interface NestedPortableRecord extends PortableRecord {}\n"
			+ "@:flat @:portable struct Point : NestedPortableRecord {\n"
			+ "\tpublic var x:Float;\n\tpublic var y:Int;\n"
			+ "\tpublic function new(x:Float, y:Int) { this.x = x; this.y = y; }\n}\n"
			+ "function requireFlat<T:Flat>(value:T):T return value;\n"
			+ "function requirePortable<T:Portable>(value:T):T return value;\n"
			+ "function relayFlat<T:Flat>(value:T):T return requireFlat(value);\n"
			+ "function main():Int {\n"
			+ "\tvar point = new Point(1.5, 2);\n\tvar flat = requireFlat(point);\n"
			+ "\tvar address = requireFlat(new Address());\n\tvar forwarded = relayFlat(point);\n\tvar portable = requirePortable(forwarded);\n"
			+ "\tvar scalar = requirePortable(42);\n"
			+ "\treturn portable.y + scalar - 2;\n}\n");
		expectError("@:flat struct HasString { public var name:String; } function main():Int return 0;", "HasString.name", "@:flat");
		expectError("struct Inner { public var name:String; } @:flat struct Outer { public var inner:Inner; } function main():Int return 0;",
			"Outer.inner.name", "@:flat");
		expectError("abstract RawPtr<T>(hl.Bytes) {} @:portable struct Address { public var pointer:RawPtr<Int>; } function main():Int return 0;",
			"Address.pointer", "@:portable");
		expectError("abstract RawPtr<T>(hl.Bytes) {} interface PortableRecord extends Portable {} interface Nested extends PortableRecord {} "
			+ "struct Address : Nested { public var pointer:RawPtr<Int>; } function main():Int return 0;",
			"Address.pointer", "struct Address");
		expectTypingError("abstract RawPtr<T>(hl.Bytes) {} struct Address { public var pointer:RawPtr<Int>; } "
			+ "function requirePortable<T:Portable>(value:T):T return value; function main():Int { requirePortable(new Address()); return 42; }",
			"Address.pointer");
		expectPortableLayouts();
		Sys.println("PASS: Flat and Portable struct properties, assertions, constraints, and interface requirements");
	}

	static function expectPortableLayouts():Void {
		var source = "struct Point { public var x:Int; public var y:Int; }\n"
			+ "struct Nested { public var enabled:Bool; public var point:Point; public var tail:Float; }\n"
			+ "struct FixedFields { public var byte:UInt8; public var word:UInt16; public var ratio:Float32; }\n"
			+ "function pointSize():Int return sizeof<Point>();\n"
			+ "function pointAlignment():Int return alignof<Point>();\n"
			+ "function pointY():Int return offsetof<Point>(\"y\");\n"
			+ "function nestedPoint():Int return offsetof<Nested>(\"point\");\n"
			+ "function nestedTail():Int return offsetof<Nested>(\"tail\");\n"
			+ "function main():Int return pointSize();";
		for (target in [
			"portable-abi32",
			"portable-abi64",
			"wasm32-wasi",
			"x86_64-pc-linux-gnu",
			"aarch64-unknown-linux-gnu"
		]) {
			var typed = Typer.typeLibrary(parse(source), target),
				point = requireClass(typed.classes, "Point"),
				nested = requireClass(typed.classes, "Nested"),
				fixed = requireClass(typed.classes, "FixedFields"),
				pointLayout = requireLayout(point.nativeLayouts, target),
				nestedLayout = requireLayout(nested.nativeLayouts, target),
				fixedLayout = requireLayout(fixed.nativeLayouts, target);
			if (!point.isFlat || !point.isPortable || !nested.isPortable || !fixed.isPortable)
				throw '$target did not infer Flat and Portable for scalar-only structs';
			if (pointLayout.size != 8 || pointLayout.alignment != 4 || layoutField(pointLayout.fields, "y").offset != 4)
				throw '$target produced a nonportable Point layout';
			if (nestedLayout.size != 24
				|| nestedLayout.alignment != 8
				|| layoutField(nestedLayout.fields, "point").offset != 4
				|| layoutField(nestedLayout.fields, "tail").offset != 16)
				throw '$target produced a nonportable Nested layout';
			if (fixedLayout.size != 8
				|| fixedLayout.alignment != 4
				|| layoutField(fixedLayout.fields, "word").offset != 2
				|| layoutField(fixedLayout.fields, "ratio").offset != 4)
				throw '$target produced a nonportable FixedFields layout';
			if (constantReturn(typed.functions, "pointSize") != 8
				|| constantReturn(typed.functions, "pointAlignment") != 4
				|| constantReturn(typed.functions, "pointY") != 4
				|| constantReturn(typed.functions, "nestedPoint") != 4
				|| constantReturn(typed.functions, "nestedTail") != 16)
				throw '$target did not fold flat-struct layout queries';
		}
		expectTypingError("struct Managed { public var name:String; } function bad():Int return sizeof<Managed>();", "no fixed native ABI layout");
	}

	static function requireClass(classes:Array<compiler.types.TypedAst.TypedClass>, name:String):compiler.types.TypedAst.TypedClass {
		for (declaration in classes)
			if (declaration.name == name)
				return declaration;
		throw 'Missing typed struct "$name"';
	}

	static function requireLayout(layouts:Array<compiler.types.TypedAst.TypedNativeLayout>, target:String):compiler.types.TypedAst.TypedNativeLayout {
		for (layout in layouts)
			if (layout.target == target)
				return layout;
		throw 'Missing struct layout for "$target"';
	}

	static function layoutField(fields:Array<compiler.types.TypedAst.TypedNativeFieldLayout>, name:String):compiler.types.TypedAst.TypedNativeFieldLayout {
		for (layout in fields)
			if (layout.name == name)
				return layout;
		throw 'Missing struct layout field "$name"';
	}

	static function constantReturn(functions:Array<compiler.types.TypedAst.TypedFunction>, name:String):Int {
		for (fn in functions)
			if (fn.name == name && fn.statements.length == 1)
				switch fn.statements[0] {
					case compiler.types.TypedAst.TypedStatement.TReturn(expression, _):
						switch expression.expression {
							case compiler.types.TypedAst.TypedExpressionKind.TIntLiteral(value): return value;
							case _: throw 'Function "$name" did not fold its layout query to an integer literal';
						}
					case _:
				}
		throw 'Missing constant-returning function "$name"';
	}

	static function expectSuccess(source:String):Void
		Typer.typeLibrary(parse(source));

	static function expectTypingError(source:String, fragment:String):Void {
		try {
			Typer.typeLibrary(parse(source));
			throw 'expected a type diagnostic containing "$fragment"';
		} catch (error:CompileError) {
			if (error.diagnostic.message.indexOf(fragment) < 0)
				throw 'expected "$fragment", got "${error.diagnostic.message}"';
		}
	}

	static function expectError(source:String, fragment:String, marker:String):Void {
		try {
			Typer.typeLibrary(parse(source));
			throw 'expected a type diagnostic containing "$fragment"';
		} catch (error:CompileError) {
			if (error.diagnostic.message.indexOf(fragment) < 0)
				throw 'expected "$fragment", got "${error.diagnostic.message}"';
			if (error.diagnostic.span.start != source.indexOf(marker))
				throw 'expected diagnostic at ${source.indexOf(marker)}, got ${error.diagnostic.span.start}';
		}
	}

	static function parse(source:String):compiler.syntax.Ast.AstProgram
		return new Parser(new Lexer(new SourceFile("StructProperties.hx", source)).tokenize()).parseProgram();
}
