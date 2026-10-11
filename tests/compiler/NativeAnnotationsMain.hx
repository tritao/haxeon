import compiler.Diagnostic.CompileError;
import compiler.Compiler;
import compiler.Source.SourceFile;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.types.NativeTypeDescriptor.NativeTypeAnnotationValue;
import compiler.types.NativeTypeDescriptorCodec;
import compiler.types.Typer;

class NativeAnnotationsMain {
	static function main():Void {
		var source = "@:annotation struct Range { public var min:Float; public var max:Float; } "
			+ "@:annotation enum abstract Replicate(Int) { var all = 1; var owner = 2; } "
			+ "@:annotation struct Options { public var label:String; public var enabled:Bool; public var parent:Null<Int>; public var count:Int; } "
			+ "@:Range(0.25, 1.0) struct Position { @:Replicate(owner) public var flags:Int; } "
			+ "@:Options(\"server\", true, null, -2) struct Config { public var id:Int; }",
			typed = Typer.typeLibrary(new Parser(new Lexer(new SourceFile("NativeAnnotations.hx", source)).tokenize()).parseProgram()),
			position = requireDescriptor(typed.nativeTypeDescriptors, "Position"),
			range = position.annotationValues[0],
			replicate = position.fields[0].annotationValues[0],
			options = requireDescriptor(typed.nativeTypeDescriptors, "Config").annotationValues[0];
		expect(range.name == "Range" && range.arguments.length == 2, "struct annotation values must use their declared fields");
		expect(range.arguments[0].name == "min"
			&& range.arguments[0].type == "Float"
			&& Type.enumEq(range.arguments[0].value, FloatValue(0.25)),
			"float annotation values must be type-checked and retained");
		expect(range.arguments[1].name == "max" && Type.enumEq(range.arguments[1].value, FloatValue(1.0)),
			"all ordered struct annotation values must be retained");
		expect(replicate.name == "Replicate"
			&& replicate.arguments.length == 1
			&& replicate.arguments[0].type == "Int"
			&& Type.enumEq(replicate.arguments[0].value, IntValue(2)),
			"enum abstract annotation values must retain the checked underlying constant");
		expect(options.arguments.length == 4
			&& Type.enumEq(options.arguments[0].value, StringValue("server"))
			&& Type.enumEq(options.arguments[1].value, BoolValue(true))
			&& Type.enumEq(options.arguments[2].value, NullValue)
			&& Type.enumEq(options.arguments[3].value, IntValue(-2)),
			"string, Boolean, nullable, and negative integer annotation constants must remain typed");
		var decoded = NativeTypeDescriptorCodec.decode(NativeTypeDescriptorCodec.encode([position]));
		expect(NativeTypeDescriptorCodec.toJson(decoded).indexOf('"value": 0.25') >= 0,
			"typed annotation values must survive descriptor artifact serialization");
		var defaultedAnnotation = Typer.typeLibrary(new Parser(new Lexer(new SourceFile("AnnotationDefaults.hx",
			"@:annotation struct Options { public var label:String; public var enabled:Bool = true; public var retries:Int = 3; } " +
			"@:Options(retries = 5, label = \"server\") struct Config { public var id:Int; } " +
			"@:Options(\"client\", retries = 2) struct MixedConfig { public var id:Int; }")).tokenize()).parseProgram()),
			defaultedValues = requireDescriptor(defaultedAnnotation.nativeTypeDescriptors, "Config").annotationValues[0].arguments,
			mixedValues = requireDescriptor(defaultedAnnotation.nativeTypeDescriptors, "MixedConfig").annotationValues[0].arguments;
		expect(defaultedValues.length == 3
			&& defaultedValues[0].name == "label"
			&& Type.enumEq(defaultedValues[0].value, StringValue("server"))
			&& defaultedValues[1].name == "enabled"
			&& Type.enumEq(defaultedValues[1].value, BoolValue(true))
			&& defaultedValues[2].name == "retries"
			&& Type.enumEq(defaultedValues[2].value, IntValue(5)),
			"named annotation arguments must canonicalize by schema order and omitted fields must use typed defaults");
		expect(Type.enumEq(mixedValues[0].value, StringValue("client"))
			&& Type.enumEq(mixedValues[1].value, BoolValue(true))
			&& Type.enumEq(mixedValues[2].value, IntValue(2)),
			"a positional prefix may be combined with named arguments and defaults");

		var incremental = new Compiler();
		incremental.update("schema/Range.hx", "package schema; @:annotation struct Range { public var min:Float; public var max:Float; }");
		incremental.update("schema/Replicate.hx", "package schema; @:annotation enum abstract Replicate(Int) { var all = 1; var owner = 2; }");
		incremental.update("game/Position.hx",
			"package game; import schema.Range; import schema.Replicate; struct Position { @:Range(0.25, 1.0) public var x:Int; @:Replicate(owner) public var flags:Int; }");
		incremental.update("game/Main.hx",
			"package game; import game.Position; class Main { static function main():Int return typeInfo<Position>().hash.length; }");
		var firstCompile = incremental.compile("game.Main", null, false),
			firstPosition = requireDescriptor(incremental.lastTypedProgram.nativeTypeDescriptors, "game.Position"),
			firstHash = firstPosition.hash;
		expect(containsString(firstCompile.module.strings, firstHash), "typeInfo for an imported annotation must publish a descriptor hash");
		incremental.update("game/Position.hx",
			"package game; import schema.Range; import schema.Replicate; struct Position { @:Range(0.5, 1.0) public var x:Int; @:Replicate(owner) public var flags:Int; }");
		var changedCompile = incremental.compile("game.Main", null, false),
			changedPosition = requireDescriptor(incremental.lastTypedProgram.nativeTypeDescriptors, "game.Position");
		expect(changedPosition.hash != firstHash && containsString(changedCompile.module.strings, changedPosition.hash),
			'editing an annotation value must update the emitted typeInfo hash (first=$firstHash, changed=${changedPosition.hash})');
		expect(changedCompile.retyped.indexOf("game.Main.main") >= 0,
			'annotation metadata edits must invalidate typeInfo callers across modules (retyped=${changedCompile.retyped})');
		expect(Type.enumEq(changedPosition.fields[0].annotationValues[0].arguments[0].value, FloatValue(0.5)),
			"imported annotation declarations must resolve and the updated artifact must hold the new value");
		incremental.update("schema/Range.hx", "package schema; @:annotation struct Range { public var floor:Float; public var ceiling:Float; }");
		var schemaCompile = incremental.compile("game.Main", null, false),
			schemaPosition = requireDescriptor(incremental.lastTypedProgram.nativeTypeDescriptors, "game.Position");
		expect(schemaPosition.fields[0].annotationValues[0].arguments[0].name == "floor",
			"annotation schema edits must refresh dependent descriptor argument names");
		expect(schemaPosition.hash != changedPosition.hash && containsString(schemaCompile.module.strings, schemaPosition.hash),
			"annotation schema edits must refresh the emitted typeInfo descriptor hash");
		expect(schemaCompile.retyped.indexOf("game.Main.main") >= 0, "annotation schema edits must invalidate imported typeInfo callers");
		var schemaHash = schemaPosition.hash;
		incremental.update("schema/Replicate.hx", "package schema; @:annotation enum abstract Replicate(Int) { var all = 1; var owner = 7; }");
		var abstractCompile = incremental.compile("game.Main", null, false),
			abstractPosition = requireDescriptor(incremental.lastTypedProgram.nativeTypeDescriptors, "game.Position");
		expect(Type.enumEq(abstractPosition.fields[1].annotationValues[0].arguments[0].value, IntValue(7)),
			"enum abstract value edits must refresh imported typed annotations");
		expect(abstractPosition.hash != schemaHash && containsString(abstractCompile.module.strings, abstractPosition.hash),
			"enum abstract value edits must refresh the emitted descriptor hash");
		expect(abstractCompile.retyped.indexOf("game.Main.main") >= 0, "enum abstract value edits must invalidate imported typeInfo callers");
		var defaultIncremental = new Compiler();
		defaultIncremental.update("schema/Options.hx",
			"package schema; @:annotation struct Options { public var label:String; public var enabled:Bool = true; }");
		defaultIncremental.update("game/Config.hx", "package game; import schema.Options; @:Options(\"server\") struct Config { public var id:Int; }");
		defaultIncremental.update("game/Main.hx",
			"package game; import game.Config; class Main { static function main():Int return typeInfo<Config>().hash.length; }");
		defaultIncremental.compile("game.Main", null, false);
		var firstConfig = requireDescriptor(defaultIncremental.lastTypedProgram.nativeTypeDescriptors, "game.Config"),
			firstConfigHash = firstConfig.hash;
		expect(Type.enumEq(firstConfig.annotationValues[0].arguments[1].value, BoolValue(true)),
			"an omitted imported annotation value must use its schema default");
		defaultIncremental.update("schema/Options.hx",
			"package schema; @:annotation struct Options { public var label:String; public var enabled:Bool = false; }");
		var defaultCompile = defaultIncremental.compile("game.Main", null, false),
			changedConfig = requireDescriptor(defaultIncremental.lastTypedProgram.nativeTypeDescriptors, "game.Config");
		expect(Type.enumEq(changedConfig.annotationValues[0].arguments[1].value, BoolValue(false))
			&& changedConfig.hash != firstConfigHash,
			"an imported annotation default edit must update typed descriptor values and hashes");
		expect(defaultCompile.retyped.indexOf("game.Main.main") >= 0, "imported annotation default edits must invalidate descriptor callers");

		expectTypeError("struct Position { @:Unknown(1) public var value:Int; }", 'Unknown annotation "Unknown"');
		expectTypeError("@:annotation class Range { public var min:Float; }", "requires a value struct");
		expectTypeError("@:annotation struct Range { public var min:Float; public var max:Float; } "
			+ "@:Range(1.0) struct Position { public var value:Int; }",
			"expects 2 arguments, got 1");
		expectTypeError("@:annotation struct Range { public var min:Float; public var max:Float; } "
			+ "@:Range(\"low\", 1.0) struct Position { public var value:Int; }",
			"annotation argument \"min\"");
		expectTypeError("@:annotation struct Range { public var min:Float; public var max:Float; } "
			+ "@:Range(1.0 + 2.0, 4.0) struct Position { public var value:Int; }",
			"compile-time scalar constants");
		expectTypeError("@:annotation struct Options { public var label:String; public var count:Int = 1; } "
			+ "@:Options(unknown = 1, label = \"server\") struct Config { public var id:Int; }",
			"unknown named argument \"unknown\"");
		expectTypeError("@:annotation struct Options { public var label:String; public var count:Int = 1; } "
			+ "@:Options(label = \"server\", label = \"client\") struct Config { public var id:Int; }",
			"Duplicate named argument \"label\"");
		expectTypeError("@:annotation struct Options { public var label:String; public var count:Int = 1; } "
			+ "@:Options(label = \"server\", 2) struct Config { public var id:Int; }",
			"Positional annotation arguments cannot follow named arguments");
		expectTypeError("@:annotation struct Options { public var enabled:Bool = !false; }", "compile-time scalar constants");
		Sys.println("PASS: declared annotations are checked and typed values reach descriptors");
	}

	static function requireDescriptor(descriptors:Array<compiler.types.NativeTypeDescriptor.NativeTypeDescriptorData>,
			name:String):compiler.types.NativeTypeDescriptor.NativeTypeDescriptorData {
		for (descriptor in descriptors)
			if (descriptor.name == name)
				return descriptor;
		throw 'Missing native type descriptor "$name"';
	}

	static function containsString(strings:Array<String>, expected:String):Bool {
		for (value in strings)
			if (value == expected)
				return true;
		return false;
	}

	static function expectTypeError(source:String, expected:String):Void {
		try {
			Typer.typeLibrary(new Parser(new Lexer(new SourceFile("InvalidAnnotation.hx", source)).tokenize()).parseProgram());
			throw 'expected an annotation diagnostic containing "$expected"';
		} catch (error:CompileError) {
			if (error.diagnostic.message.indexOf(expected) < 0)
				throw 'expected "$expected", got "${error.diagnostic.message}"';
		}
	}

	static function expect(condition:Bool, message:String):Void
		if (!condition)
			throw message;
}
