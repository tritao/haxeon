import compiler.hl.HlCode;
import compiler.Frontend;
import compiler.Diagnostic.CompileError;
import compiler.Source.SourceFile;
import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.HlFunction;
import compiler.hl.HlFunction.HlInstruction;
import compiler.hl.HlType;
import compiler.hl.HlWriter;
import compiler.hl.HlPatchWriter;
import compiler.hl.HlPatchReader;
import compiler.hl.HlOpcode;
import compiler.ir.HlLower;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrGenerator;
import compiler.ir.IrTypeCodec;
import compiler.ir.IrValueTableCodec;
import compiler.ir.SsaBuilder;
import compiler.ir.Cfg.CfgInstruction;
import compiler.ir.Cfg.CfgBlock;
import compiler.ir.Cfg.CfgFunction;
import compiler.ir.Cfg.CfgValue;
import compiler.ir.CfgVerifier;
import compiler.Lexer;
import compiler.Parser;
import compiler.types.Typer;
import compiler.types.TypeRegistry;
import compiler.types.TypeRegistry.TypeCompatibility;
import compiler.modules.Compiler;
import haxe.io.Bytes as HaxeBytes;
import haxe.io.BytesInput;

class TestMain {
	static function main():Void {
		var values = [
			-0x1FFFFFFF,
			-0x2000,
			-0x1FFF,
			-0x80,
			-1,
			0,
			1,
			0x7F,
			0x80,
			0x1FFF,
			0x2000,
			0x1FFFFFFF,
		];
		for (value in values) {
			var decoded = decodeIndex(new BytesInput(HlWriter.encodeIndex(value)));
			if (decoded != value)
				throw 'index round trip failed: $value became $decoded';
		}
		Sys.println("PASS: signed HLB index boundary cases round trip");

		var invalid = new HlCode();
		invalid.types = [Simple(HlType.Void), Function([], 0)];
		invalid.functions = [new HlFunction(1, 0, [0], [Return(0)])];
		invalid.entryPoint = 1;
		expectError(invalid, "Entry point 1 is not a function");

		var unknownLabel = baseControlFlowModule();
		unknownLabel.functions = [
			new HlFunction(2, 0, [1, 1], [JumpSignedLessOrEqual(0, 1, "missing"), Return(0),])
		];
		expectError(unknownLabel, 'Unknown label "missing" in function 0');

		var duplicateLabel = baseControlFlowModule();
		duplicateLabel.functions = [new HlFunction(2, 0, [1], [Label("same"), Label("same"), Return(0),])];
		expectError(duplicateLabel, 'Duplicate label "same" in function 0');
		Sys.println("PASS: malformed module is rejected before serialization");

		var patchCode = baseControlFlowModule();
		patchCode.ints = [42];
		patchCode.types.push(Simple(HlType.Dyn));
		patchCode.types.push(Function([], 1));
		patchCode.functions = [
			new HlFunction(2, 0, [1], [LoadInt(0, 0), Return(0)]),
			new HlFunction(4, 1, [1, 3, 3], [
				LoadInt(0, 0),
				ToDyn(1, 0),
				Trap(2, "catch"),
				EndTrap(2),
				Return(0),
				Label("catch"),
				Throw(2)
			]),
		];
		var testModuleId = haxe.io.Bytes.alloc(16),
			stableBySlot:Map<Int, Int> = [];
		stableBySlot.set(1, 0x10001);
		var patchBytes = HlPatchWriter.encode(patchCode, testModuleId, [1], stableBySlot, 7, 8),
			patch = HlPatchReader.decode(patchBytes);
		if (patch.baseRevision != 7
			|| patch.revision != 8
			|| patch.functions.length != 1
			|| patch.functions[0].functionIndex != 0x10001)
			throw "HLP round trip lost revision or function identity";
		if (patch.functions[0].instructions.length != 7
			|| patch.functions[0].instructions[1].opcode != HlOpcode.ToDyn
			|| patch.functions[0].instructions[2].opcode != HlOpcode.Trap
			|| patch.functions[0].instructions[3].opcode != HlOpcode.EndTrap
			|| patch.functions[0].instructions[6].opcode != HlOpcode.Throw)
			throw "HLP round trip lost function bytecode";
		try {
			HlPatchReader.decode(patchBytes.sub(0, patchBytes.length - 1));
			throw "truncated HLP was accepted";
		} catch (error:String) {
			if (error != "Truncated HLP data")
				throw error;
		}
		var extended = haxe.io.Bytes.alloc(patchBytes.length + 3);
		extended.blit(0, patchBytes, 0, patchBytes.length);
		extended.set(22, 3);
		extended.set(patchBytes.length, 99);
		extended.set(patchBytes.length + 1, 1);
		extended.set(patchBytes.length + 2, 42);
		if (HlPatchReader.decode(extended).functions.length != 1)
			throw "unknown HLP section changed known data";
		Sys.println("PASS: selective HLP functions and revisions round trip strictly");

		var ir = new IrProgram("main");
		var builder = new IrBuilder();
		builder.constInt(7);
		var repeated = builder.constInt(7);
		builder.returnValue(repeated);
		ir.functions.push(new IrFunction("main", [], IrType.I32, builder.blocks));
		var lowered = HlLower.lower(ir);
		if (lowered.ints.length != 1 || lowered.ints[0] != 7)
			throw "IR lowering did not deduplicate integer constants";
		if (lowered.functions[0].registers.length != 2)
			throw "IR lowering did not allocate registers for temporary values";
		Sys.println("PASS: IR lowering allocates registers and deduplicates constants");

		expectCompileError('function main():Int { return missing; }', 'Unknown variable "missing"');
		expectCompileError('function add(a:Int, b:Int):Int { return a+b; } function main():Int { return add(1); }',
			'Function "add" expects 2 arguments, got 1');
		expectCompileError('function main():Int { if (1 < 2) return 1; }', 'Function main does not return on every path');
		expectCompileError('function main():Int { if (1) return 1; else return 2; }', 'If condition must be Bool');
		expectCompileError('function text():String { return "hello"; } function main():Int { var value:Float = 1.25; var wrong:String = value; return 0; }',
			'Type mismatch for local "wrong"');
		expectCompileError('function main():Int { missing = 1; return 0; }', 'Unknown variable "missing"');
		expectCompileError('function main():Int { var value:Int = 1; value = "wrong"; return value; }', 'Type mismatch for local "value"');
		expectCompileError('function main():Int { throw; }', 'Expected expression');
		expectCompileError('function noop():Void { return; } function main():Int { throw noop(); }', 'Cannot throw a Void value');
		expectCompileError('function main():Int { throw null; }', 'Cannot throw null');
		expectCompileError('function main():Int { try { return 42; } catch (error:Array<Int>) { return 0; } }', 'Unsupported catch binding type');
		expectCompileError('function main():Int { try { return 42; } catch (error:Dynamic) { return 0; } catch (text:String) { return 1; } }',
			'Dynamic catch must be the final catch clause');
		expectCompileError('class Box { public function values():Array<Int> { return new Array<Int>(0); } public function add():Void { this.values().push(1); } } function main():Int { return 0; }',
			'Array.push requires a mutable local or field array');
		expectCompileError('function main():Int { return 1; var unreachable = 2; }', 'Unreachable statement');
		expectCompileError('enum Color { Red; Blue; } function main():Int { var color:Color = Color.Red; switch (color) { case Color.Red: return 1; case Color.Red: return 2; case Color.Blue: return 3; } }',
			"Duplicate switch case");
		expectCompileError('enum Color { Red; Blue; } function main():Int { var color:Color = Color.Red; switch (color) { case Color.Red: return 1; } return 0; }',
			"Enum switch is missing cases: Blue");
		expectCompileError('enum Color { Red; Blue; } function choose(color:Color):Int { switch (color) { case Color.Red: return 1; default: } } function main():Int { return choose(Color.Red); }',
			'Function choose does not return on every path');
		var ssa = Frontend.compile('function main():Int { var value = 0; while (value < 2) { value = value + 1; } return value; }'), hasPhi = false;
		for (fn in ssa.functions)
			for (block in fn.blocks)
				for (instruction in block.instructions)
					switch instruction {
						case compiler.ir.Ir.IrInstruction.Phi(_, _):
							hasPhi = true;
						default:
					}
		if (!hasPhi)
			throw "Mutable loop did not construct an SSA phi";
		var mutableSource = 'function main():Int { var outer = 0; while (outer < 2) { var inner = 0; while (inner < 2) { inner = inner + 1; } outer = outer + inner; } return outer; }';
		var ast = new Parser(new Lexer(new SourceFile("ssa.hx", mutableSource)).tokenize()).parseProgram();
		var typed = Typer.type(ast), cfg = IrGenerator.generateCfg(typed.functions[0]), loads = 0, stores = 0;
		for (block in cfg.blocks)
			for (instruction in block.instructions)
				switch instruction {
					case LoadLocal(_, _):
						loads++;
					case StoreLocal(_, _):
						stores++;
					default:
				}
		if (loads == 0 || stores == 0)
			throw "Typed AST did not lower through mutable-local CFG";
		var built = SsaBuilder.build(cfg), phis = 0;
		for (block in built.blocks)
			for (instruction in block.instructions)
				switch instruction {
					case compiler.ir.Ir.IrInstruction.Phi(_, _):
						phis++;
					default:
				}
		if (phis != 2)
			throw 'Pruned SSA expected two live loop phis, got $phis';
		Sys.println("PASS: mutable CFG lowers through pruned dominance-based SSA");

		var unterminated = new CfgBlock(0);
		expectCfgError(new CfgFunction("bad", [], I32, [unterminated], []), "Reachable CFG block 0 in bad has no terminator");
		var badTarget = new CfgBlock(0);
		badTarget.terminator = compiler.ir.Cfg.CfgTerminator.Jump(4);
		expectCfgError(new CfgFunction("bad", [], I32, [badTarget], []), "Unknown CFG block 4");
		var duplicate = new CfgBlock(0),
			first = new CfgValue(0, I32),
			again = new CfgValue(0, I32);
		duplicate.instructions.push(ConstInt(first, 1));
		duplicate.instructions.push(ConstInt(again, 2));
		duplicate.terminator = compiler.ir.Cfg.CfgTerminator.Return(again);
		expectCfgError(new CfgFunction("bad", [], I32, [duplicate], []), "Duplicate CFG value 0");
		var crossBlockA = new CfgBlock(0),
			crossBlockB = new CfgBlock(1),
			crossValue = new CfgValue(0, I32);
		crossBlockA.instructions.push(ConstInt(crossValue, 1));
		crossBlockA.terminator = compiler.ir.Cfg.CfgTerminator.Jump(1);
		crossBlockB.terminator = compiler.ir.Cfg.CfgTerminator.Return(crossValue);
		expectCfgError(new CfgFunction("bad", [], I32, [crossBlockA, crossBlockB], []), "CFG value 0 is used outside its defining block or before definition");
		Sys.println("PASS: CFG verifier rejects malformed blocks, edges, and values");
		var persistedType = Function([I32, Array(Obj("demo.Box")), Function([Bytes], Bool)], Virtual("demo.Plugin")),
			persistedTypeBytes = IrTypeCodec.encode(persistedType);
		if (Std.string(IrTypeCodec.decode(persistedTypeBytes)) != Std.string(persistedType)
			|| persistedTypeBytes.compare(IrTypeCodec.encode(persistedType)) != 0)
			throw "IR type state did not round trip deterministically";
		var trailingType = HaxeBytes.alloc(persistedTypeBytes.length + 1);
		trailingType.blit(0, persistedTypeBytes, 0, persistedTypeBytes.length);
		expectStringError(function() IrTypeCodec.decode(trailingType), "Trailing IR type state data");
		var unknownType = persistedTypeBytes.sub(0, persistedTypeBytes.length);
		unknownType.set(4, 255);
		expectStringError(function() IrTypeCodec.decode(unknownType), "Unknown IR type tag");
		Sys.println("PASS: IR types persist deterministically and reject malformed state");
		var persistedValues = [
			new compiler.ir.Ir.IrValue(9, "result", I32),
			new compiler.ir.Ir.IrValue(2, "input", Array(Bytes))
		], persistedValueBytes = IrValueTableCodec.encode(persistedValues), decodedValues = IrValueTableCodec.decode(persistedValueBytes);
		if ((decodedValues[0].id : Int) != 2
			|| (decodedValues[1].id : Int) != 9
				|| Std.string(decodedValues[0].type) != Std.string(Array(Bytes))
				|| persistedValueBytes.compare(IrValueTableCodec.encode(persistedValues)) != 0)
			throw "IR value table did not round trip canonically";
		var badReference = IrValueTableCodec.byId(decodedValues);
		var referenceBytes = new haxe.io.BytesOutput();
		referenceBytes.bigEndian = false;
		referenceBytes.writeInt32(99);
		expectStringError(function() IrValueTableCodec.readReference(new BytesInput(referenceBytes.getBytes()), badReference), "Unknown IR value reference");
		Sys.println("PASS: canonical IR value tables preserve identity and reject unknown references");
		var types = new TypeRegistry();
		var firstType = types.declareClass("demo.Box", null, [{name: "value", type: "Int"}], [{name: "get", signature: "():Int"}]);
		if (firstType.compatibility != NewType || firstType.descriptor.fields[0].slot != 0)
			throw "Initial type declaration was not classified or laid out correctly";
		var stableTypeId = firstType.descriptor.id,
			stableFieldId = firstType.descriptor.fields[0].id,
			stableMethodId = firstType.descriptor.methods[0].id;
		var compatible = types.declareClass("demo.Box", null, [{name: "value", type: "Int"}], [{name: "get", signature: "():Int"}]);
		if (compatible.compatibility != Compatible)
			throw "Unchanged type was not classified as compatible";
		if (types.declareClass("demo.Box", null, [{name: "value", type: "Int"}], [{name: "get", signature: "():String"}])
			.compatibility != MethodSignatureChanged)
			throw "Method signature change was not classified as reload-incompatible";
		if (types.declareClass("demo.Box", null, [{name: "value", type: "String"}], [{name: "get", signature: "():Int"}]).compatibility != LayoutChanged)
			throw "Field layout change was not classified as reload-incompatible";
		var restored = new TypeRegistry(types.exportState()),
			restoredType = restored.declareClass("demo.Box", null, [{name: "value", type: "Int"}], [{name: "get", signature: "():Int"}]).descriptor;
		if (restoredType.id != stableTypeId || restoredType.fields[0].id != stableFieldId || restoredType.methods[0].id != stableMethodId)
			throw "Type identities did not survive persistence and restart";
		var identityCompiler = new Compiler();
		var identityDeclaration = identityCompiler.types.declareClass("demo.Persistent", null, [{name: "value", type: "Int"}], []);
		var resumedTypes = new Compiler(identityCompiler.exportIdentityState()).types;
		if (resumedTypes.declareClass("demo.Persistent", null, [{name: "value", type: "Int"}], []).descriptor.id != identityDeclaration.descriptor.id)
			throw "Compiler identity state did not preserve nominal type IDs";
		var abiCompiler = new Compiler();
		abiCompiler.update("Main.hx", "class Box { public var value:Int; } function main():Int { return 42; }");
		abiCompiler.compile("Main");
		var abiState = abiCompiler.exportIdentityState();
		if (abiState.compare(abiCompiler.exportIdentityState()) != 0)
			throw "Published ABI persistence was not deterministic";
		var resumedAbiCompiler = new Compiler(abiState);
		resumedAbiCompiler.update("Main.hx", "class Box { public var value:String; } function main():Int { return 42; }");
		if (!resumedAbiCompiler.compile("Main").requiresReload)
			throw "Compiler restart lost the published ABI compatibility baseline";
		var trailingAbiState = HaxeBytes.alloc(abiState.length + 1);
		trailingAbiState.blit(0, abiState, 0, abiState.length);
		expectIdentityError(trailingAbiState, "Trailing compiler identity data");
		var unsupportedAbiState = HaxeBytes.alloc(abiState.length);
		unsupportedAbiState.blit(0, abiState, 0, abiState.length);
		unsupportedAbiState.set(3, 2);
		expectIdentityError(unsupportedAbiState, "Invalid compiler identity state");
		Sys.println("PASS: stable nominal identities and layout compatibility survive restart");
		var packaged = new Parser(new Lexer(new SourceFile("pkg.hx",
			"package editor.core; import editor.util; function main():Int { return 42; }")).tokenize()).parseProgram();
		if (packaged.packageName != "editor.core" || packaged.imports.length != 1 || packaged.imports[0] != "editor.util")
			throw "Package and import declarations were not preserved in the AST";
		Sys.println("PASS: package and import declarations are represented in the frontend");
		var aliasProgram = new Parser(new Lexer(new SourceFile("aliases.hx",
			"typedef Number = Int; function add(value:Number):Number { return value; } function main():Int { return add(42); }")).tokenize()).parseProgram();
		if (aliasProgram.aliases.length != 1
			|| Typer.type(aliasProgram).functions[0].arguments[0].type != compiler.types.Type.CompilerType.TInt)
			throw "Type aliases were not resolved by the typer";
		Sys.println("PASS: primitive type aliases resolve through the typed AST");
		var classProgram = new Parser(new Lexer(new SourceFile("Box.hx",
			"package demo; class Box { public final value:Int; public function new(value:Int) { } public function get():Int { return 42; } } function main():Int { return 42; }"))
			.tokenize()).parseProgram();
		if (classProgram.classes.length != 1
			|| classProgram.classes[0].fields[0].name != "value"
			|| classProgram.classes[0].methods.length != 2
			|| classProgram.classes[0].methods[0].name != "new")
			throw "Minimal class declarations were not preserved in the AST";
		var typedClass = Typer.type(classProgram);
		if (typedClass.classes.length != 1
			|| typedClass.classes[0].fields[0].type != compiler.types.Type.CompilerType.TInt
			|| typedClass.classes[0].methods[1].result != compiler.types.Type.CompilerType.TInt)
			throw "Minimal class declarations were not type checked";
		var libraryProgram = new Parser(new Lexer(new SourceFile("Library.hx",
			"class LibraryBox { public function get():Int { return 42; } } function helper(value:Int):Int { return value; }")).tokenize()).parseProgram();
		var typedLibrary = Typer.typeLibrary(libraryProgram),
			hasHelper = false;
		for (fn in typedLibrary.functions)
			if (fn.name == "helper")
				hasHelper = true;
		if (typedLibrary.classes.length != 1 || !hasHelper)
			throw "Library modules were not type checked without an executable main";
		var interfaceSource = "interface Plugin { function activate():Void; function score(value:Int):Int; } class SearchPlugin implements Plugin { public function activate():Void { } public function score(value:Int):Int { return value; } } function consume(plugin:Plugin):Int { plugin.activate(); return plugin.score(42); } function main():Int { var plugin:Plugin = new SearchPlugin(); return consume(plugin); }",
			interfaceProgram = new Parser(new Lexer(new SourceFile("Plugin.hx", interfaceSource)).tokenize()).parseProgram();
		if (interfaceProgram.interfaces.length != 1 || interfaceProgram.classes[0].interfaces[0] != "Plugin")
			throw "Interface declarations were not preserved in the AST";
		var interfaceTyped = Typer.type(interfaceProgram);
		if (interfaceTyped.classes[0].interfaces.length != 1)
			throw "Class interface contracts were not retained in the typed AST";
		expectCompileError("interface Plugin { function activate():Void; } class Missing implements Plugin { } function main():Int { return 0; }",
			'Class "Missing" does not implement "Plugin.activate"');
		var interfaceCompiler = new Compiler(),
			interfaceV1 = "interface Plugin { function score(value:Int):Int; } class SearchPlugin implements Plugin { public function score(value:Int):Int { return value; } } function consume(plugin:Plugin):Int { return plugin.score(42); } function main():Int { return consume(new SearchPlugin()); }";
		interfaceCompiler.update("Main.hx", interfaceV1);
		interfaceCompiler.compile("Main");
		interfaceCompiler.update("Main.hx",
			"interface Plugin { function changed(value:Int):Int; } class SearchPlugin implements Plugin { public function score(value:Int):Int { return value; } } function main():Int { return 0; }");
		try {
			interfaceCompiler.compile("Main");
			throw "incompatible interface edit was accepted";
		} catch (error:CompileError) {
			if (error.diagnostic.code != "E1007")
				throw error;
		}
		interfaceCompiler.update("Main.hx", interfaceV1);
		if (interfaceCompiler.compile("Main").requiresReload)
			throw "Restoring an unpublished invalid interface contract required reload";
		var staticClass = Frontend.compile("class Math { public static function add(a:Int, b:Int):Int { return a + b; } } function main():Int { return Math.add(20, 22); }");
		var foundStatic = false;
		for (fn in staticClass.functions)
			if (fn.name == "Math.add")
				foundStatic = true;
		if (!foundStatic)
			throw "Static class method was not lowered as a callable function";
		var objectCode = new HlCode();
		objectCode.ints = [42];
		objectCode.strings = ["Box", "value"];
		objectCode.types = [
			                                                        Simple(HlType.Void), Simple(HlType.I32),
			compiler.hl.HlCode.HlTypeDef.Object(0, -1, 0, [{name: 1, type: 1}], [], []),    Function([], 1)
		];
		objectCode.functions = [new HlFunction(3, 0, [1], [LoadInt(0, 0), Return(0)])];
		objectCode.entryPoint = 0;
		if (HlWriter.encode(objectCode).length == 0)
			throw "HashLink object type did not serialize";
		var incrementalClass = new Compiler();
		incrementalClass.update("Main.hx",
			"class Math { public static function add(a:Int, b:Int):Int { return a + b; } } function main():Int { return Math.add(20, 22); }");
		var incrementalResult = incrementalClass.compile("Main");
		if (!incrementalResult.functionIndices.exists("Math.add") || incrementalResult.retyped.join(",") != "Math.add,main")
			throw "Incremental compiler did not retain the static class method as a function";
		Sys.println("PASS: class fields, methods, and constructors parse as nominal declarations");
		Sys.println("PASS: typer rejects invalid names, calls, conditions, and return paths");

		try {
			Frontend.compileFile(new SourceFile("broken.hx", "function main():Int { return @; }"));
			throw "compiler accepted invalid character";
		} catch (error:CompileError) {
			if (error.diagnostic.code != "E0001" || error.diagnostic.span.file.path != "broken.hx" || error.diagnostic.span.start != 29)
				throw "structured source diagnostic has the wrong code or span";
		}
		Sys.println("PASS: syntax diagnostics retain file-aware source spans");
	}

	static function baseControlFlowModule():HlCode {
		var code = new HlCode();
		code.types = [Simple(HlType.Void), Simple(HlType.I32), Function([], 1)];
		code.entryPoint = 0;
		return code;
	}

	static function expectError(code:HlCode, expected:String):Void {
		try {
			HlWriter.encode(code);
			throw 'writer accepted invalid module; expected "$expected"';
		} catch (error:String) {
			if (error != expected)
				throw error;
		}
	}

	static function expectCompileError(source:String, expected:String):Void {
		try {
			Frontend.compile(source);
			throw 'compiler accepted invalid source; expected "$expected"';
		} catch (error:CompileError) {
			if (error.diagnostic.message != expected)
				throw error;
		}
	}

	static function expectCfgError(cfg:CfgFunction, expected:String):Void {
		try {
			CfgVerifier.verify(cfg);
			throw 'CFG verifier accepted invalid graph; expected "$expected"';
		} catch (error:String) {
			if (error != expected)
				throw error;
		}
	}

	static function expectIdentityError(state:HaxeBytes, expected:String):Void {
		try {
			new Compiler(state);
			throw 'compiler accepted invalid identity state; expected "$expected"';
		} catch (error:String) {
			if (error != expected)
				throw error;
		}
	}

	static function expectStringError(action:Void->Void, expected:String):Void {
		try {
			action();
			throw 'operation succeeded; expected "$expected"';
		} catch (error:String) {
			if (error != expected)
				throw error;
		}
	}

	static function decodeIndex(input:BytesInput):Int {
		var first = input.readByte();
		if ((first & 0x80) == 0)
			return first & 0x7F;
		if ((first & 0x40) == 0) {
			var value = input.readByte() | ((first & 31) << 8);
			return (first & 0x20) == 0 ? value : -value;
		}
		var value = ((first & 31) << 24) | (input.readByte() << 16) | (input.readByte() << 8) | input.readByte();
		return (first & 0x20) == 0 ? value : -value;
	}
}
