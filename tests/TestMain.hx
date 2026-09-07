import compiler.hl.HlCode;
import compiler.Frontend;
import compiler.Diagnostic.CompileError;
import compiler.Source.SourceFile;
import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.HlFunction;
import compiler.hl.HlFunction.HlInstruction;
import compiler.hl.HlType;
import compiler.hl.HlWriter;
import compiler.hl.patch.HlPatchWriter;
import compiler.hl.patch.HlPatchReader;
import compiler.hl.HlOpcode;
import compiler.hl.incremental.HlSymbolTable;
import compiler.hl.persistence.HlTypeDefStateCodec;
import compiler.hl.persistence.HlSymbolStateCodec;
import compiler.hl.incremental.HlFunctionCache;
import compiler.hl.persistence.HlFunctionCacheStateCodec;
import compiler.hl.incremental.HlModuleAssembler;
import compiler.hl.persistence.HlAssemblerStateCodec;
import compiler.abi.PatchPlanner.PatchDecision;
import compiler.semantic.SemanticSignature;
import compiler.semantic.GenericSpecializationRegistry;
import compiler.ir.hl.HlLower;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrGenerator;
import compiler.ir.codec.IrTypeCodec;
import compiler.ir.codec.IrValueTableCodec;
import compiler.ir.codec.IrTerminatorCodec;
import compiler.ir.codec.IrInstructionCodec;
import compiler.ir.codec.IrFunctionStateCodec;
import compiler.ir.cfg.SsaBuilder;
import compiler.ir.cfg.Cfg.CfgInstruction;
import compiler.ir.cfg.Cfg.CfgBlock;
import compiler.ir.cfg.Cfg.CfgFunction;
import compiler.ir.cfg.Cfg.CfgValue;
import compiler.ir.cfg.CfgVerifier;
import compiler.ir.SourceProvenance;
import compiler.ir.SourceProvenance.Located;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.types.Typer;
import compiler.types.TypeRegistry;
import compiler.types.TypeRegistry.TypeCompatibility;
import compiler.Compiler;
import haxe.io.Bytes as HaxeBytes;
import haxe.io.BytesInput;
import Type as HaxeType;

class TestMain {
	static function located<T>(value:T):Located<T>
		return new Located(value, SourceProvenance.generated("malformed-test-fixture"));

	static function main():Void {
		var lexicalForms = new Lexer(new SourceFile("lexical-forms.hx", "// line\n/* block */ 'text' ? @")).tokenize();
		if (lexicalForms.length != 4
			|| lexicalForms[0].kind != compiler.syntax.Token.TokenKind.StringLiteral
			|| lexicalForms[1].kind != compiler.syntax.Token.TokenKind.Question
			|| lexicalForms[2].kind != compiler.syntax.Token.TokenKind.At)
			throw "Common Haxe lexical forms were not tokenized";
		var unicodeSource = new SourceFile("unicode.hx", "é\nx");
		if (unicodeSource.bytes.length != 4
			|| unicodeSource.slice(0, 2) != "é"
			|| unicodeSource.lineAt(3) != 2
			|| unicodeSource.byteOffsetAt(1, 1) != 4
			|| unicodeSource.lspPosition(4).character != 1)
			throw "Unicode source indexing did not preserve byte and LSP offsets";
		var unicodeTokens = new Lexer(new SourceFile("unicode-token.hx", "\"é\"")).tokenize();
		if (unicodeTokens[0].text != "\"é\"" || unicodeTokens[0].span.end != 4)
			throw "Unicode tokenization did not preserve UTF-8 byte spans";
		var hexTokens = new Lexer(new SourceFile("hex.hx", "0x2A 0Xff")).tokenize();
		if (hexTokens[0].text != "0x2A" || hexTokens[1].text != "0Xff")
			throw "Hexadecimal integer literals were not tokenized";
		Frontend.compile('function main():Int return "=".code;');
		Frontend.compile('function main():Int { return 0x2A; }');
		Frontend.compile('enum Kind { Void; Float; } function main():Int { var value:Kind = Kind.Float; return switch value { case Kind.Void: 0; case Kind.Float: 42; }; }');
		Frontend.compile('enum Kind { First; Second; } function main():Int { var value:Kind = Second; return switch value { case First: 0; case Second: 42; }; }');
		Frontend.compile('enum Result { Value(value:Int, ?message:String); } function main():Int { var result:Result = Result.Value(42); switch result { case Result.Value(value): return value; } }');
		Frontend.compile('enum Result { Values(values:Array<Int>); } function main():Int { var result:Result = Values([40, 2]); return switch result { case Values([first, second]): first + second; default: 0; }; }');
		Frontend.compile('enum Severity { Error; Warning; } function severity(?value:Severity = Error):Severity return value; function main():Int { var value = severity(); return 42; }');
		Frontend.compile('enum Value { Present(value:Int); } function main():Int { var value:Null<Value> = true ? null : Present(42); return 42; }');
		Frontend.compile('enum Value { Present(value:Int); } function main():Int { var value:Value = Present(1); value = Present(42); return 42; }');
		Frontend.compile('enum Value { Present(value:Null<String>); } function identity(value:Value):Value return value; function build():Value { var value = null; return identity(Present(value)); } function main():Int { build(); return 42; }');
		Frontend.compile('typedef Value = { number:Int }; function main():Int { var values:Array<Value> = [{ number: 1 }]; values[0] = { number: 42 }; var value:Null<Value> = switch 0 { case 0: values[0]; default: null; }; return 42; }');
		Frontend.compile('enum Mixed { Value(?first:String, second:Int); } function main():Int { var value:Mixed = Mixed.Value(null, 42); return 42; }');
		Frontend.compile('typedef Options = { final ?name:String; ?final count:Int; } function main():Int { return 42; }');
		Frontend.compile('enum Value { Present; } typedef Options = { ?value:Value }; function main():Int { var options:Options = { value: null }; return 42; }');
		Frontend.compile('function main():Int { var values = [20, 22]; var empty:Array<Int> = []; return values[0] + values[1] + empty.length; }');
		Frontend.compile('function main():Int { var values = [20, 22]; values.insert(1, 1); return values[1] + 41; }');
		Frontend.compile('function main():Int { var values:Map<String, Int> = []; values.set("answer", 42); if (!values.exists("answer")) return 0; return values.get("answer"); }');
		Frontend.compile('function main():Int { var values:Map<String, Int> = []; values.set("answer", 42); return values.get("answer"); }');
		Frontend.compile('function main():Int { var values:Map<String, Int> = []; values["answer"] = 42; return values["answer"]; }');
		Frontend.compile('function main():Int { var values:Map<String, Bool> = []; values["answer"] = true; values.clear(); values["answer"] = true; return values.get("answer") ? 42 : 0; }');
		Frontend.compile('function main():Int { var values:Map<String, Int> = ["answer" => 42]; for (key in values.keys()) return values.get(key); return 0; }');
		expectCompileError('function main():Int { var values:Map<String, Int> = []; return values.get("answer"); }', "Type mismatch for return");
		expectCompileError('function main():Int { var values:Map<String, Int> = []; if (values.exists("answer")) { values.remove("answer"); return values.get("answer"); } return 0; }',
			"Type mismatch for return");
		expectCompileError('function main():Int { var values:Map<String, Int> = ["answer" => 42]; for (key in values.keys()) { values.remove(key); return values.get(key); } return 0; }',
			"Type mismatch for return");
		Frontend.compile('function value(flag:Bool):Int { var result:Null<Int> = flag ? 1 : null; if (result == null) result = 2; return result; } function main():Int return value(false);');
		Frontend.compile('function main():Int { return "A".charCodeAt(0); }');
		Frontend.compile('function main():Int { return "A".charAt(0) == "A" ? 42 : 0; }');
		Frontend.compile('function main():Int { return String.fromCharCode(65) == "A" ? 42 : 0; }');
		Frontend.compile('class Value { public function new() { } } function main():Int { var value = true ? new Value() : null; return value == null ? 0 : 42; }');
		Frontend.compile('class Value { public final number:Int = 42; public function new() { } } function fail():Void throw "missing"; function main():Int { var value:Null<Value> = new Value(); if (value == null) fail(); return value.number; }');
		Frontend.compile('class Value { public final number:Int = 42; public function new() { } } function main():Int { var value:Null<Value> = new Value(); if (value != null && value.number == 42) return value.number; return 0; }');
		Frontend.compile('class Value { public final number:Int = 42; public function new() { } } class Holder { public var value:Null<Value> = null; public function new(value:Null<Value>) { this.value = value; } } function main():Int { var holder = new Holder(new Value()); if (holder.value != null) return holder.value.number; return 0; }');
		expectCompileError('class Value { public final number:Int = 42; public function new() { } } class Holder { public var value:Null<Value> = null; public function new(value:Null<Value>) { this.value = value; } } function main():Int { var holder = new Holder(new Value()); if (holder.value != null) { holder.value = null; return holder.value.number; } return 0; }',
			'Field "number" requires an object');
		Frontend.compile('function make():String return "value"; function main():Int { var value = null; if (true) value = make(); return value == null ? 0 : 42; }');
		Frontend.compile('function make():String return "value"; function main():Int { var values = []; values.push(make()); return values.length; }');
		Frontend.compile('function main():Int { var values = [3, 1, 2]; values.sort(function(left, right) return left - right); return values[0] + values[1] + values[2] + 36; }');
		expectCompileError('function invalid():Void return 42; function main():Int return 0;', 'Type mismatch for return');
		Frontend.compile('function main():Int { var values = ["a", "b"]; return values.join(",") == "a,b" ? 42 : 0; }');
		Frontend.compile('function apply(callback:(Int, Int)->Int):Int return callback(1, 2); function main():Int return apply(function(_, _) return 42);');
		Frontend.compile('function choose<T>(value:T, enabled:Bool = true):T return value; function main():Int return choose(42);');
		Frontend.compile('function choose<T>(value:T, ?message:String):T return value; function main():Int return choose(42);');
		Frontend.compile('class GenericDefaults { public static function same<T>(expected:T, actual:T, message:String = ""):Bool return expected == actual; } function main():Int return GenericDefaults.same(42, 42) ? 42 : 0;');
		expectCompileError('function choose<T>(value:T, enabled:Bool = true):T return value; function main():Int return choose();',
			'Function "choose" expects 1 to 2 arguments, got 0');
		Frontend.compile('function fail():Void throw "failure"; function value():String { fail(); return null; } function main():Int return 42;');
		Frontend.compile('function fail():Void throw "failure"; function value():String return if (true) "value" else { fail(); null; }; function main():Int return 42;');
		Typer.typeLibrary(new Parser(new Lexer(new SourceFile("infinite-loop.hx",
			"function parse():Int { while (true) { continue; } }")).tokenize()).parseProgram());
		Frontend.compile('function values():Array<Int> { var result = []; result.push(42); return result; } function main():Int { return values()[0]; }');
		Frontend.compile('typedef Result = { values:Array<Int> }; function values():Result { var values = []; return { values: values }; } function main():Int return values().values.length;');
		new Parser(new Lexer(new SourceFile("expression-block-statements.hx",
			'function main():Int return if (true) { var value = 0; if (true) value = 21; else value = 0; value + 21; } else 0;')).tokenize()).parseProgram();
		var privateAlias = new Parser(new Lexer(new SourceFile("private-alias.hx", "private typedef Internal = Int;")).tokenize()).parseProgram();
		if (!privateAlias.aliases[0].isPrivate)
			throw "Private type alias visibility was not preserved";
		new Parser(new Lexer(new SourceFile("terminating-switch-expression.hx",
			'function main():Int { var value = switch 0 { case 0: return 42; default: 0; }; return value; }')).tokenize()).parseProgram();
		Frontend.compile('function main():Int { switch 0 { case 0: return 42; default: return 0; }; }');
		expectCompileError('function main():Int { var values = []; return 0; }', 'Empty array literal requires an expected element type');
		Frontend.compile('function main():Int { var value:Int; do { value = 42; } while (false); return value; }');
		expectCompileError('function main():Int { do { return 1; } while (1); }', 'Do-while condition must be Bool');
		expectCompileError('function main():Int { do { break; } while (true); return 0; }', 'break in do-while is not supported by the current CFG backend');
		expectCompileError('function main():Int { do { continue; } while (true); return 0; }',
			'continue in do-while is not supported by the current CFG backend');
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
			], [
				for (line in 10...17)
					{
						path: "patch-debug.hx",
						line: line,
						start: null,
						end: null,
						column: 1,
						endLine: line,
						endColumn: 1,
						sourceHash: 0,
						flags: 0
					}
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
		if (patch.debugFiles.length != 1
			|| patch.debugFiles[0] != "patch-debug.hx"
			|| patch.functions[0].debug.length != 7
			|| patch.functions[0].debug[0].line != 10
			|| patch.functions[0].debug[6].line != 16)
			throw "HLP round trip lost function debug metadata";
		try {
			HlPatchReader.decode(patchBytes.sub(0, patchBytes.length - 1));
			throw "truncated HLP was accepted";
		} catch (error:String) {
			if (error != "Truncated HLP data")
				throw error;
		}
		var extended = HlPatchWriter.encode(patchCode, testModuleId, [1], stableBySlot, 7, 8, 0, 0, 0, 0, [{tag: 99, bytes: haxe.io.Bytes.ofString("*")}]);
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
		expectCompileError('function main():Int { return 1 ? 2 : 3; }', 'Conditional expression requires a Bool condition');
		Frontend.compile('typedef Holder = { value:Null<String> }; function read(holder:Holder):Int return holder.value != null && holder.value.length > 0 ? 1 : 0; function main():Int return 0;');
		Frontend.compile('typedef Location = { path:String, start:Null<Int> }; function contains(location:Location, path:String, minimum:Int):Bool return location.path == path && location.start != null && location.start >= minimum; function main():Int return 0;');
		Frontend.compile('function nullablePrimitive(value:Int):Null<Int> return value; function main():Int return nullablePrimitive(42) == null ? 0 : 42;');
		Frontend.compile('function main():Int { var values:Map<String, Array<Int>> = []; var found = values.get("key"); return found == null ? 0 : found.length; }');
		Frontend.compile('enum Choice { First; Second; } function choose(flag:Bool, other:Choice):Choice return flag ? First : other; function reverse(flag:Bool, other:Choice):Choice return flag ? other : Second; function main():Int return 0;');
		Frontend.compile('function choose(value:Null<String>):Int { var chosen = value == null ? (true ? "fallback" : "unused") : value; return chosen.length; } function main():Int return choose(null);');
		Frontend.compile('class Values { public var items:Null<Array<Int>>; public function new(items:Null<Array<Int>>) { this.items = items; } } function choose(values:Values):Array<Int> { var result = values.items == null ? [] : values.items; return result; } function main():Int return choose(new Values(null)).length;');
		Frontend.compile('typedef ValuesRecord = { items:Null<Array<Int>> }; function choose(values:ValuesRecord):Array<Int> { var result = values.items == null ? [] : values.items; return result; } function main():Int return 0;');
		Frontend.compile('typedef OptionalValues = { ?items:Array<Int> }; function choose(values:OptionalValues):Array<Int> { var result = values.items == null ? [] : values.items; return result; } function main():Int return 0;');
		Frontend.compile('function choose(value:Null<String>):Int { switch 1 { case 1 if (value != null): return value.length; default: return 0; } } function main():Int return choose(null);');
		Frontend.compile('function choose(value:Null<String>):Int return switch 1 { case 1 if (value != null): value.length; default: 0; }; function main():Int return choose(null);');
		expectCompileError('function main():Int { var value = true ? 1 : "wrong"; return 0; }', 'Conditional branches must have matching types');
		expectCompileError('function main():Int { return switch 1 { case 1: 42; }; }', 'Switch expression requires a default branch');
		expectCompileError('function main():Int { return switch 1 { case 1: 42; default: "wrong"; }; }', 'Type mismatch for switch branch');
		expectCompileError('function main():Int { return switch 1 { case 1: 40; case 1: 2; default: 0; }; }', 'Duplicate switch case');
		Frontend.compile('function main():Int { var value = switch 2 { case 1, 2: 42; default: 0; }; switch (value) { case 41, 42: return value; default: return 0; } }');
		Frontend.compile('function main():Int { switch 42 { case 42: return 42; default: return 0; } }');
		expectCompileError('function text():String { return "hello"; } function main():Int { var value:Float = 1.25; var wrong:String = value; return 0; }',
			'Type mismatch for local "wrong"');
		expectCompileError('function main():Int { missing = 1; return 0; }', 'Unknown variable "missing"');
		expectCompileError('function main():Int { var value:Int; return value; }', 'Local "value" may be used before assignment');
		expectCompileError('function main():Int { var value:Int; if (true) value = 42; return value; }', 'Local "value" may be used before assignment');
		expectCompileError('function main():Int { var value:Int; value++; return value; }', 'Local "value" may be used before assignment');
		Frontend.compile('class Box { public var value:Int; public function new() { this.value = 1; } } function main():Int { var box = new Box(); var old = box.value++; return old + box.value; }');
		expectCompileError('function main():Int { var text = "x"; return text++; }', 'Postfix increment requires a numeric target');
		expectCompileError('function main():Int { var value; return 0; }', 'Uninitialized local "value" requires an explicit type');
		expectCompileError('class Invalid { static final value; } function main():Int { return 0; }', 'Field "value" requires a type or initializer');
		expectCompileError('class Invalid { static final value = 20 + 22; } function main():Int { return 0; }',
			'Cannot infer type of field "value" from this initializer');
		Frontend.compile("class Defaults { static final integer = -1; static final fraction = -0.5; static final prefix = '$' + 'abstract-' + 'result'; } function main():Int { return Defaults.integer; }");
		expectCompileError('class Invalid { static final value = "count: " + 1; } function main():Int { return 0; }',
			'Cannot infer type of field "value" from this initializer');
		expectCompileError('class Invalid { static final value:Int = "wrong"; } function main():Int { return 0; }',
			'Type mismatch for static field "Invalid.value"');
		expectCompileError('function main():Int { var value:Int = 1; value = "wrong"; return value; }', 'Type mismatch for local "value"');
		expectCompileError('function main():Int { throw; }', 'Expected expression');
		expectCompileError('function noop():Void { return; } function main():Int { throw noop(); }', 'Cannot throw a Void value');
		expectCompileError('function main():Int { throw null; }', 'Cannot throw null');
		expectCompileError('function main():Int { try { return 42; } catch (error:Array<Int>) { return 0; } }', 'Unsupported catch binding type');
		expectCompileError('function main():Int { try { return 42; } catch (error:Dynamic) { return 0; } catch (text:String) { return 1; } }',
			'Dynamic catch must be the final catch clause');
		Frontend.compile('class Box { public function values():Array<Int> { return new Array<Int>(0); } public function add():Void { this.values().push(1); } } function main():Int { return 0; }');
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
					switch instruction.value {
						case compiler.ir.Ir.IrInstruction.Phi(_, _):
							hasPhi = true;
						default:
					}
		if (!hasPhi)
			throw "Mutable loop did not construct an SSA phi";
		var conditional = Frontend.compile('function main():Int { var value = true ? 40 : 2; return value; }'),
			conditionalHasPhi = false;
		for (fn in conditional.functions)
			for (block in fn.blocks)
				for (instruction in block.instructions)
					switch instruction.value {
						case compiler.ir.Ir.IrInstruction.Phi(_, _):
							conditionalHasPhi = true;
						default:
					}
		if (!conditionalHasPhi)
			throw "Conditional expression did not merge branch values through SSA";
		Frontend.compile('function main():Int { var sideEffect = 0; var value = if (true) { sideEffect++; 40; } else { 2; }; return value + sideEffect; }');
		Frontend.compile('function main():Int { return switch 1 { case 1: 42; default: throw "unexpected"; }; }');
		Frontend.compile('function main():Int { return if (true) 42 else throw "unexpected"; }');
		Frontend.compile('function main():Int { var value = switch 1 { case 1: 42; default: 0; } return value; }');
		Frontend.compile('function main():Int { var values:Array<Int> = [42]; do values.push(0) while (false); return values[0]; }');
		Frontend.compile('function main():Int { return if (true) 42; else { 0; }; }');
		Frontend.compile('function main():Int { return if (true) { var value = 42; value; } else 0; }');
		new Parser(new Lexer(new SourceFile("contextual-expression-name.hx",
			'function main():Int { return String.fromCharCode(42).length; }')).tokenize()).parseProgram();
		var inferredSignatures = new Parser(new Lexer(new SourceFile("inferred-signatures.hx",
			'class Value { public function new(value) {} public function read() { return 42; } }')).tokenize()).parseProgram();
		if (inferredSignatures.classes[0].methods[0].arguments[0].type != compiler.syntax.Ast.AstType.InferredType
			|| inferredSignatures.classes[0].methods[1].result != compiler.syntax.Ast.AstType.InferredType)
			throw "Missing function annotations were not preserved for semantic inference";
		var mutableSource = 'function main():Int { var outer = 0; while (outer < 2) { var inner = 0; while (inner < 2) { inner = inner + 1; } outer = outer + inner; } return outer; }';
		var ast = new Parser(new Lexer(new SourceFile("ssa.hx", mutableSource)).tokenize()).parseProgram();
		var typed = Typer.type(ast), cfg = IrGenerator.generateCfg(typed.functions[0]), loads = 0, stores = 0;
		for (block in cfg.blocks)
			for (instruction in block.instructions)
				switch instruction.value {
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
				switch instruction.value {
					case compiler.ir.Ir.IrInstruction.Phi(_, _):
						phis++;
					default:
				}
		if (phis != 2)
			throw 'Pruned SSA expected two live loop phis, got $phis';
		Sys.println("PASS: mutable CFG lowers through pruned dominance-based SSA");

		var unterminated = new CfgBlock(0);
		expectCfgError(new CfgFunction("bad", [], I32, [unterminated], [], 0), "Reachable CFG block 0 in bad has no terminator");
		var badTarget = new CfgBlock(0);
		badTarget.terminator = located(compiler.ir.cfg.Cfg.CfgTerminator.Jump(4));
		expectCfgError(new CfgFunction("bad", [], I32, [badTarget], [], 0), "Unknown CFG block 4");
		var duplicate = new CfgBlock(0),
			first = new CfgValue(0, I32),
			again = new CfgValue(0, I32);
		duplicate.instructions.push(located(ConstInt(first, 1)));
		duplicate.instructions.push(located(ConstInt(again, 2)));
		duplicate.terminator = located(compiler.ir.cfg.Cfg.CfgTerminator.Return(again));
		expectCfgError(new CfgFunction("bad", [], I32, [duplicate], [], 1), "Duplicate CFG value 0");
		var crossBlockA = new CfgBlock(0),
			crossBlockB = new CfgBlock(1),
			crossValue = new CfgValue(0, I32);
		crossBlockA.instructions.push(located(ConstInt(crossValue, 1)));
		crossBlockA.terminator = located(compiler.ir.cfg.Cfg.CfgTerminator.Jump(1));
		crossBlockB.terminator = located(compiler.ir.cfg.Cfg.CfgTerminator.Return(crossValue));
		expectCfgError(new CfgFunction("bad", [], I32, [crossBlockA, crossBlockB], [], 1),
			"CFG value 0 is used outside its defining block or before definition in block 1");
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
		var instructionProgram = Frontend.compile("function add(a:Int, b:Int):Int { var sum = a + b; return sum; } function main():Int { return add(20, 22); }");
		var decodedFunctions = [];
		for (fn in instructionProgram.functions) {
			var instructionValues:Map<Int, compiler.ir.Ir.IrValue> = [];
			for (argument in fn.arguments)
				instructionValues.set(argument.id, argument);
			for (block in fn.blocks)
				for (instruction in block.instructions)
					for (parameter in HaxeType.enumParameters(instruction.value))
						collectInstructionValues(parameter, instructionValues);
			for (block in fn.blocks)
				for (instruction in block.instructions) {
					var encoded = IrInstructionCodec.encode(instruction.value),
						decoded = IrInstructionCodec.decode(encoded, instructionValues);
					if (Std.string(decoded) != Std.string(instruction.value))
						throw "IR instruction did not round trip";
				}
		}
		Sys.println("PASS: explicit IR instructions round trip through canonical value references");
		for (fn in instructionProgram.functions) {
			var encodedFunction = IrFunctionStateCodec.encode(fn),
				decodedFunction = IrFunctionStateCodec.decode(encodedFunction);
			if (decodedFunction.name != fn.name
				|| decodedFunction.blocks.length != fn.blocks.length
				|| encodedFunction.compare(IrFunctionStateCodec.encode(decodedFunction)) != 0)
				throw "IR function state did not round trip deterministically";
			decodedFunctions.push(decodedFunction);
		}
		IrFunctionStateCodec.verify(decodedFunctions, instructionProgram);
		var provenanceProgram = Frontend.compileFile(new SourceFile("debug-lines.hx", "function main():Int {\n  var value = 41;\n  return value + 1;\n}")),
			provenanceLines:Map<Int, Bool> = [];
		for (fn in provenanceProgram.functions)
			if (fn.name == "main")
				for (block in fn.blocks) {
					for (instruction in block.instructions) {
						var location = instruction.provenance.location;
						if (location != null && location.path == "debug-lines.hx")
							provenanceLines.set(location.line, true);
					}
					var terminator = block.terminator;
					if (terminator != null && terminator.provenance.location != null)
						provenanceLines.set(terminator.provenance.location.line, true);
				}
		if (!provenanceLines.exists(2) || !provenanceLines.exists(3))
			throw "SSA IR did not retain expression and statement source lines";
		var debugCode = HlLower.lower(provenanceProgram),
			debugBytes = HlWriter.encode(debugCode);
		if (debugBytes.get(4) != 1)
			throw "HLB writer did not enable function debug metadata";
		for (fn in debugCode.functions)
			if (fn.debugLocations.length != fn.opcodes.length)
				throw "HashLink opcode debug locations are not total";
		Sys.println("PASS: source provenance survives SSA and covers every lowered HashLink opcode");
		var functionCache = new HlFunctionCache();
		functionCache.update(instructionProgram.functions);
		var functionCacheBytes = HlFunctionCacheStateCodec.encode(functionCache.exportState()),
			restoredFunctionCache = HlFunctionCacheStateCodec.restore(functionCacheBytes);
		if (functionCacheBytes.compare(HlFunctionCacheStateCodec.encode(restoredFunctionCache.exportState())) != 0
			|| restoredFunctionCache.slots.length != functionCache.slots.length)
			throw "HashLink function cache did not round trip deterministically";
		var persistedAssembler = new HlModuleAssembler();
		persistedAssembler.assemble(instructionProgram, [for (fn in instructionProgram.functions) fn.name], Patch);
		var assemblerBytes = HlAssemblerStateCodec.encode(persistedAssembler),
			restoredAssembler = HlAssemblerStateCodec.decode(assemblerBytes);
		if (assemblerBytes.compare(HlAssemblerStateCodec.encode(restoredAssembler)) != 0)
			throw "HashLink assembler baseline did not round trip deterministically";
		Sys.println("PASS: complete IR functions persist deterministically");
		var symbolTable = new HlSymbolTable();
		var intIndex = symbolTable.internInt(42),
			stringIndex = symbolTable.internString("stable"),
			typeIndex = symbolTable.internType(I32);
		var restoredSymbols = HlSymbolTable.fromState(symbolTable.exportState());
		if (restoredSymbols.internInt(42) != intIndex
			|| restoredSymbols.internString("stable") != stringIndex
			|| restoredSymbols.internType(I32) != typeIndex)
			throw "Restored HashLink symbol lookup changed persistent indices";
		var encodedTypes = HlTypeDefStateCodec.encode(symbolTable.types),
			decodedTypes = HlTypeDefStateCodec.decode(encodedTypes, symbolTable.strings.length, symbolTable.globals.length);
		if (Std.string(decodedTypes) != Std.string(symbolTable.types)
			|| encodedTypes.compare(HlTypeDefStateCodec.encode(decodedTypes)) != 0)
			throw "HashLink type definitions did not round trip deterministically";
		var parameterizedTypes = [Simple(HlType.I32), Parameterized(HlType.Ref, 0), Parameterized(HlType.Null, 1)],
			parameterizedState = HlTypeDefStateCodec.encode(parameterizedTypes);
		if (parameterizedState.compare(HlTypeDefStateCodec.encode(HlTypeDefStateCodec.decode(parameterizedState, 0, 0))) != 0)
			throw "Parameterized HashLink type state did not round trip deterministically";
		var symbolBytes = HlSymbolStateCodec.encode(symbolTable.exportState()),
			binarySymbols = HlSymbolStateCodec.restore(symbolBytes);
		if (symbolBytes.compare(HlSymbolStateCodec.encode(binarySymbols.exportState())) != 0 || binarySymbols.internInt(42) != intIndex)
			throw "HashLink symbol binary state did not round trip deterministically";
		Sys.println("PASS: HashLink symbol state restores canonical lookup indices");
		var terminatorOutput = new haxe.io.BytesOutput(),
			terminatorBlocks:Map<Int, Bool> = [];
		terminatorOutput.bigEndian = false;
		terminatorBlocks.set(4, true);
		terminatorBlocks.set(7, true);
		IrTerminatorCodec.write(terminatorOutput, Branch(decodedValues[1], 4, 7));
		var decodedTerminator = IrTerminatorCodec.read(new BytesInput(terminatorOutput.getBytes()), IrValueTableCodec.byId(decodedValues), terminatorBlocks);
		switch decodedTerminator {
			case Branch(condition, yes, no):
				if ((condition.id : Int) != 9 || yes != 4 || no != 7)
					throw "IR branch terminator did not round trip";
			default:
				throw "IR branch terminator decoded as the wrong variant";
		}
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
			"package editor.core; import editor.util; import haxe.io.Bytes as HaxeBytes; function main():Int { return 42; }")).tokenize()).parseProgram();
		if (packaged.packageName != "editor.core"
			|| packaged.imports.length != 2
			|| packaged.imports[0] != "editor.util"
			|| packaged.importAliases.get("HaxeBytes") != "haxe.io.Bytes")
			throw "Package and import declarations were not preserved in the AST";
		Sys.println("PASS: package and import declarations are represented in the frontend");
		var nestedTypeCompiler = new Compiler();
		nestedTypeCompiler.update("sample/Types.hx", "package sample; typedef Inner = Int;");
		nestedTypeCompiler.update("Main.hx", "import sample.Types.Inner; function main():Int { var value:Inner = 42; return value; }");
		nestedTypeCompiler.compile("Main");
		var moduleImportCompiler = new Compiler();
		moduleImportCompiler.update("sample/Types.hx", "package sample; class Types {} class Inner { public function new() {} }");
		moduleImportCompiler.update("Main.hx", "import sample.Types; function main():Int { new Inner(); return 0; }");
		moduleImportCompiler.compile("Main");
		var methodDependencyCompiler = new Compiler();
		methodDependencyCompiler.update("sample/Failure.hx", "package sample; class Failure { public function new() {} }");
		methodDependencyCompiler.update("sample/Service.hx",
			"package sample; import sample.Failure as Problem; class Service { static final VALUES:Map<String, Bool> = [\"known\" => true]; public static function create():Failure return new Problem(); public static function known():Bool return VALUES.exists(\"known\"); public static function character():String return String.fromCharCode(65); }");
		methodDependencyCompiler.update("Main.hx", "import sample.Service; function main():Int { Service.create(); return 0; }");
		methodDependencyCompiler.compile("Main");
		var platformType = new Parser(new Lexer(new SourceFile("Platform.hx", "function size(value:haxe.io.Bytes):Int return 0;")).tokenize()).parseProgram();
		Typer.typeLibrary(platformType);
		Sys.println("PASS: nested module and platform type names resolve canonically");
		Frontend.compile("class InferredConstructor { final value:Int; public function new(value) { this.value = value; } } function main():Int return new InferredConstructor(42).value;");
		Frontend.compile("class InferredConditionalConstructor { final values:Array<Int>; public function new(?values) { this.values = values == null ? [] : values; } } function main():Int return new InferredConditionalConstructor([42]).values[0];");
		Frontend.compile("class InferredCalls { public function new() {} function target(value:Int):Int return value; public function forward(value):Int return this.target(value); } function main():Int return new InferredCalls().forward(42);");
		Frontend.compile("class OptionalConstructor { public function new(?value:String) {} } function main():Int { new OptionalConstructor(); return 42; }");
		var voidEntryCompiler = new Compiler();
		voidEntryCompiler.update("Main.hx", "class Main { public static function main():Void {} }");
		voidEntryCompiler.compile("Main");
		Sys.println("PASS: constructor parameters infer from declared field constraints");
		var metadataProgram = new Parser(new Lexer(new SourceFile("Native.hx",
			'@:hlNative("sample") private class Native { @:noCompletion public static function read():Int return @:privateAccess 42; }')).tokenize())
			.parseProgram();
		if (!metadataProgram.classes[0].isPrivate
			|| metadataProgram.classes[0].metadata[0].name != "hlNative"
			|| metadataProgram.classes[0].metadata[0].arguments.length != 1)
			throw "Class metadata and top-level visibility were not preserved";
		Sys.println("PASS: declaration and expression metadata parse explicitly");
		var externProgram = Frontend.compile('@:hlNative("std", "sys_time") extern function nativeTime():Float; function main():Int { nativeTime(); return 42; }');
		var nativeTime = null;
		for (native in externProgram.natives)
			if (native.name == "nativeTime")
				nativeTime = native;
		var emittedExternBody = false;
		for (fn in externProgram.functions)
			if (fn.name == "nativeTime")
				emittedExternBody = true;
		if (nativeTime == null || nativeTime.library != "std" || nativeTime.symbol != "sys_time" || emittedExternBody)
			throw "Source extern native binding was not preserved without emitting a body";
		var nativeStubProgram = Frontend.compile('@:hlNative("sample") private class Native { public static function read():Int return 0; } function main():Int { Native.read(); return 42; }');
		var nativeStub = false, emittedStub = false;
		for (native in nativeStubProgram.natives)
			if (native.name == "Native.read" && native.library == "sample" && native.symbol == "read")
				nativeStub = true;
		for (fn in nativeStubProgram.functions)
			if (fn.name == "Native.read")
				emittedStub = true;
		if (!nativeStub || emittedStub)
			throw "Class-level native metadata did not replace Haxe stub bodies";
		expectCompileError('extern function missing():Int; function main():Int return 42;', 'Extern function "missing" requires @:hlNative(library, symbol)');
		expectCompileError('@:hlNative("std") extern function malformed():Int; function main():Int return 42;',
			"@:hlNative requires a library and symbol string");
		expectCompileError('@:hlNative("one", "two") extern class Native { public static function read():Int; } function main():Int return 42;',
			"Declaration @:hlNative requires one library string");
		expectCompileError('@:hlNative(42) extern class Native { public static function read():Int; } function main():Int return 42;',
			"Declaration @:hlNative library must be a string literal");
		var modularExtern = new Compiler();
		modularExtern.update("Main.hx", '@:hlNative("std", "sys_time") extern function nativeTime():Float; function main():Int { nativeTime(); return 42; }');
		modularExtern.compile("Main");
		var externClass = new Compiler();
		externClass.update("Clock.hx", 'extern class Clock { @:hlNative("std", "sys_time") public static function now():Float; }');
		externClass.update("Main.hx", 'import Clock; function main():Int { Clock.now(); return 42; }');
		externClass.compile("Main");
		var externAbstract = new Compiler();
		externAbstract.update("Clock.hx", 'extern abstract Clock(Float) { @:hlNative("std", "sys_time") public static function now():Float; }');
		externAbstract.update("Main.hx", 'import Clock; function main():Int { Clock.now(); return 42; }');
		externAbstract.compile("Main");
		Sys.println("PASS: extern functions lower through validated HashLink native bindings");
		var nativeHandleProgram = new Parser(new Lexer(new SourceFile("NativeHandle.hx",
			'function identity(value:hl.Abstract<"module">):hl.Abstract<"module"> { return value; }')).tokenize()).parseProgram(),
			nativeHandleTyped = Typer.typeLibrary(nativeHandleProgram),
			nativeHandleType = compiler.types.Type.CompilerType.TNativeAbstract("module");
		if (!compiler.types.TypeRelations.equals(nativeHandleTyped.functions[0].arguments[0].type, nativeHandleType)
			|| !compiler.types.TypeRelations.equals(nativeHandleTyped.functions[0].result, nativeHandleType))
			throw "Tagged native abstract type was not preserved semantically";
		expectCompileError('function invalid(value:UserHandle<"module">):Int return 0;', 'Type "UserHandle" does not accept a native ABI tag');
		var aliasProgram = new Parser(new Lexer(new SourceFile("aliases.hx",
			"typedef Number = Int; function add(value:Number):Number { return value; } function main():Int { return add(42); }")).tokenize()).parseProgram();
		if (aliasProgram.aliases.length != 1
			|| Typer.type(aliasProgram).functions[0].arguments[0].type != compiler.types.Type.CompilerType.TInt)
			throw "Type aliases were not resolved by the typer";
		Sys.println("PASS: primitive type aliases resolve through the typed AST");
		var genericAliasProgram = new Parser(new Lexer(new SourceFile("generic-aliases.hx",
			"typedef Pair<T> = { left:T, right:T }; function main():Int { var value:Pair<Int> = { left: 20, right: 22 }; return value.left + value.right; }"))
			.tokenize()).parseProgram();
		var genericAliasTyped = Typer.type(genericAliasProgram);
		if (genericAliasTyped.functions[0].result != compiler.types.Type.CompilerType.TInt)
			throw "Generic type aliases were not substituted by the typer";
		Sys.println("PASS: generic type aliases substitute their arguments");
		var genericAbstractProgram = new Parser(new Lexer(new SourceFile("generic-abstracts.hx",
			"abstract Identity<T>(T) from T to T { public function new(value:T) { this = value; } public static function wrap(value:T):Identity<T> return value; public function unwrap():T return this; } function read(value:Identity<Int>):Int return value; function main():Int return read(Identity.wrap(42)) + new Identity<Int>(0).unwrap();"))
			.tokenize()).parseProgram();
		var boundedProgram = new Parser(new Lexer(new SourceFile("bounded-generics.hx",
			"interface Readable { function read():Int; } class Value implements Readable { public function new() {} public function read():Int return 42; } function consume<T:Readable>(value:T):Int return value.read(); function main():Int return consume(new Value());"))
			.tokenize()).parseProgram();
		if (boundedProgram.functions[0].typeConstraints == null || boundedProgram.functions[0].typeConstraints.length != 1)
			throw "Bounded generic constraint was not preserved by the parser";
		var boundedTyped = Typer.type(boundedProgram),
			boundedPolicyFound = false;
		for (fn in boundedTyped.functions)
			if (fn.name.indexOf("[constrained]") >= 0)
				boundedPolicyFound = true;
		if (!boundedPolicyFound)
			throw "Bounded specialization did not persist its concrete policy";
		Frontend.compile("interface Readable { function read():Int; } interface Writable { function write():Int; } class Both implements Readable, Writable { public function new() {} public function read():Int return 40; public function write():Int return 2; } function consume<T:(Readable, Writable)>(value:T):Int return value.read() + value.write(); function main():Int return consume(new Both());");
		Frontend.compile("interface Readable { function read():Int; } class Value implements Readable { public function new() {} public function read():Int return 42; } class Pair<T, U:T> {} function main():Int { var pair:Pair<Readable, Value>; return 42; }");
		Frontend.compile("interface Readable { function read():Int; } class Value implements Readable { public function new() {} public function read():Int return 42; } class Box<T:Readable> { public function new() {} } function main():Int { var box:Box<Value> = new Box<Value>(); return 42; }");
		expectCompileError("interface Readable { function read():Int; } class Box<T:Readable> {} function main():Int { var box:Box<Int>; return 0; }",
			'Type argument for "T" on "Box" does not satisfy constraint "interface:Readable<>"');
		expectCompileError("interface Readable { function read():Int; } function consume<T:Readable>(value:T):Int return value.read(); function main():Int return consume(42);",
			'Type argument for "T" does not satisfy constraint "interface:Readable<>"');
		if (genericAbstractProgram.abstracts[0].typeParameters.join(",") != "T")
			throw "Generic abstract type parameters were not preserved";
		var genericAbstractTyped = Typer.type(genericAbstractProgram);
		switch genericAbstractTyped.functions[0].arguments[0].type {
			case compiler.types.Type.CompilerType.TAbstract("Identity", [compiler.types.Type.CompilerType.TInt], compiler.types.Type.CompilerType.TInt):
			default:
				throw "Applied generic abstract did not preserve its identity and instantiated representation";
		}
		expectCompileError("abstract Identity<T>(T) {} function main():Int { var value:Identity = 42; return value; }",
			'Type "Identity" expects 1 type arguments, got 0');
		expectCompileError("abstract Identity<T>(T) {} function main():Int { var value:Identity<Int, String> = 42; return value; }",
			'Type "Identity" expects 1 type arguments, got 2');
		expectCompileError("abstract Wrapped<T>(T) {} function main():Int { var value:Wrapped<Int> = 42; return 0; }", 'Type mismatch for local "value"');
		expectCompileError("abstract Wrapped<T>(T) from T {} function unwrap(value:Wrapped<Int>):Int return value; function main():Int return 0;",
			'Type mismatch for return');
		expectCompileError("abstract Wrapped<T>(T) from T from T {} function main():Int return 0;",
			'Duplicate from conversion "type-parameter:Wrapped:T" on abstract "Wrapped"');
		expectCompileError("abstract A(Int) from B {} abstract B(Int) from A {} function main():Int return 0;", 'Cyclic from conversion involving "A"');
		expectCompileError("abstract A(Int) to B {} abstract B(Int) to A {} function main():Int return 0;", 'Cyclic to conversion involving "A"');
		expectCompileError("abstract A(Int) to B to C {} abstract B(Int) to D {} abstract C(Int) to D {} abstract D(Int) {} function main():Int return 0;",
			'Ambiguous to conversion paths from "A" to "D"');
		expectCompileError("abstract A(Int) from B from C {} abstract B(Int) from D {} abstract C(Int) from D {} abstract D(Int) {} function main():Int return 0;",
			'Ambiguous from conversion paths from "D" to "A"');
		Frontend.compile("abstract A<T>(T) to B<T> to B<Array<T>> {} abstract B<T>(T) {} function main():Int return 0;");
		expectCompileError("abstract A(Int) from Int to B {} abstract B(Int) from A to Int {} function read(value:A):Int return value; function main():Int return 0;",
			"Type mismatch for return");
		expectCompileError("abstract Bad(Int) { public function new(value:String) { this = value; } } function main():Int { new Bad(\"bad\"); return 0; }",
			'Type mismatch for abstract constructor "Bad.new"');
		var computedAbstract = new Parser(new Lexer(new SourceFile("computed-abstract.hx",
			"abstract Offset(Int) { public function new(value:Int, offset:Int) { var computed = value + offset; this = computed; } } function main():Int { new Offset(40, 2); return 0; }"))
			.tokenize()).parseProgram();
		var computedAbstractTyped = Typer.type(computedAbstract),
			computedConstructors = [
				for (fn in computedAbstractTyped.functions)
					if (StringTools.startsWith(fn.name, "$generic:Offset.new")) fn
			];
		if (computedConstructors.length != 1 || computedConstructors[0].result != compiler.types.Type.CompilerType.TInt)
			throw "Computed abstract constructor was not normalized to a representation-returning function";
		var branchingAbstract = new Parser(new Lexer(new SourceFile("branching-abstract.hx",
			"abstract Choice(Int) { public function new(value:Int, fallback:Int, useValue:Bool) { if (useValue) { this = value; return; } else { this = fallback; } } } function main():Int { new Choice(42, 0, true); return 0; }"))
			.tokenize()).parseProgram();
		Typer.type(branchingAbstract);
		expectCompileError("abstract Bad(Int) { public function new(value:Int, assign:Bool) { if (assign) this = value; } } function main():Int { new Bad(1, true); return 0; }",
			'Abstract constructor "Bad.new" does not initialize this on every path');
		expectCompileError("abstract Bad(Int) { public function new(value:Int) { return value; } } function main():Int { new Bad(1); return 0; }",
			"Abstract constructors cannot return a value");
		expectCompileError("abstract Loop<T>(Loop<T>) {} function main():Int return 0;", 'Cyclic abstract representation involving "Loop"');
		var modularAbstract = new Compiler();
		var modularAbstractDeclaration = "abstract Identity<T>(T) from T to T { public function new(value:T) { this = value; } public static function wrap(value:T):Identity<T> return value; public function unwrap():T return this; }",
			modularAbstractMain = "import Identity; function main():Int return Identity.wrap(new Identity<Int>(42).unwrap()).unwrap();";
		modularAbstract.update("Identity.hx", modularAbstractDeclaration);
		modularAbstract.update("Main.hx", modularAbstractMain);
		var modularAbstractBuild = modularAbstract.compile("Main"),
			modularAbstractBodies = [
				for (fn in modularAbstractBuild.ir.functions)
					if (StringTools.startsWith(fn.name, "$generic:Identity.")) fn.name
			];
		var resumedAbstract = new Compiler(modularAbstract.exportIdentityState());
		resumedAbstract.update("Identity.hx", modularAbstractDeclaration);
		resumedAbstract.update("Main.hx", modularAbstractMain);
		var resumedAbstractBuild = resumedAbstract.compile("Main"),
			resumedAbstractBodies = [
				for (fn in resumedAbstractBuild.ir.functions)
					if (StringTools.startsWith(fn.name, "$generic:Identity.")) fn.name
			];
		modularAbstractBodies.sort(Reflect.compare);
		resumedAbstractBodies.sort(Reflect.compare);
		if (modularAbstractBodies.length != 3 || modularAbstractBodies.join(",") != resumedAbstractBodies.join(","))
			throw "Generic abstract method specializations did not survive compiler restart";
		Sys.println("PASS: generic abstracts resolve instantiated representations across modules");
		var conversionCompiler = new Compiler();
		conversionCompiler.update("Value.hx", "abstract Value(Int) from Int to Int {}");
		conversionCompiler.update("Main.hx", "import Value; function read(value:Value):Int return value; function main():Int return read(42);");
		conversionCompiler.compile("Main");
		conversionCompiler.update("Value.hx", "abstract Value(Int) from Int {}");
		try {
			conversionCompiler.compile("Main");
			throw "Removing an abstract conversion did not retype its cross-module consumer";
		} catch (error:CompileError) {
			if (error.diagnostic.message != "Type mismatch for return")
				throw error;
		}
		Sys.println("PASS: abstract conversion edits invalidate cross-module consumers");
		var genericNominalProgram = new Parser(new Lexer(new SourceFile("generic-nominals.hx",
			"interface Source<T> { function get():T; } class Box<T> { var value:T; public function new(value:T) { this.value = value; } public function get():T return value; } function consume(value:Box<Int>):Int return 42; function main():Int return 42;"))
			.tokenize()).parseProgram();
		var genericNominalModel = compiler.semantic.SemanticProgram.analyze(genericNominalProgram);
		var genericNominalType = genericNominalModel.declarations.resolve(genericNominalProgram.functions[0].arguments[0].type);
		switch genericNominalType {
			case compiler.types.Type.CompilerType.TInstance(Class, "Box", [compiler.types.Type.CompilerType.TInt]):
			default:
				throw "Generic nominal arguments were not preserved semantically";
		}
		Sys.println("PASS: generic class and interface arguments resolve semantically");
		expectCompileError("interface Source<T> { function get():T; } class TextSource implements Source<String> { public function get():String return \"no\"; } function consume(value:Source<Int>):Int return 42; function main():Int return consume(new TextSource());",
			'Type mismatch for argument 1 to "consume"');
		var genericReloadCompiler = new Compiler();
		genericReloadCompiler.update("Main.hx",
			"class Box<T> { public function new() {} } function main():Int { var value:Box<Int> = new Box<Int>(); return 42; }");
		genericReloadCompiler.compile("Main");
		genericReloadCompiler.update("Main.hx",
			"class Box<T> { public function new() {} } function main():Int { var value:Box<String> = new Box<String>(); return 42; }");
		if (genericReloadCompiler.compile("Main").requiresReload)
			throw "Semantic-only generic argument change required runtime reload";
		Sys.println("PASS: erased generic argument edits remain hot-patch compatible");
		expectCompileError("function consume(value:Missing):Int { return 0; } function main():Int { return 0; }", 'Unknown type "Missing"');
		expectCompileError("typedef Loop = Loop; function main():Int { return 0; }", 'Cyclic type alias involving "Loop"');
		expectCompileError("class Loop extends Loop { } function main():Int { return 0; }", 'Cyclic class inheritance involving "Loop"');
		expectCompileError("class Loop<T> extends Loop<Array<T>> { } function main():Int { return 0; }", 'Cyclic class inheritance involving "Loop"');
		expectCompileError("interface Root<T> {} interface Left extends Root<Int> {} interface Right extends Root<String> {} interface Diamond extends Left, Right {} function main():Int return 0;",
			'Conflicting inherited interface instantiations for "Root": Root<Int> and Root<String>');
		Frontend.compile("interface Root<T> {} interface Left<T> extends Root<T> {} interface Right<T> extends Root<T> {} interface Diamond<T> extends Left<T>, Right<T> {} function main():Int return 42;");
		var modularDiamond = new Compiler();
		modularDiamond.update("Root.hx", "interface Root<T> { function value():T; }");
		modularDiamond.update("Left.hx", "import Root; interface Left<T> extends Root<T> {}");
		modularDiamond.update("Right.hx", "import Root; interface Right<T> extends Root<T> {}");
		modularDiamond.update("Main.hx",
			"import Left; import Right; interface Diamond<T> extends Left<T>, Right<T> {} class Value implements Diamond<Int> { public function value():Int return 42; } function main():Int return new Value().value();");
		modularDiamond.compile("Main");
		var modularDiamondBaseline = modularDiamond.exportIdentityState();
		modularDiamond.update("Right.hx", "import Root; interface Right<T> extends Root<String> {}");
		try {
			modularDiamond.compile("Main");
			throw "Cross-module conflicting generic diamond was accepted";
		} catch (error:CompileError) {
			if (error.diagnostic.code != "E1020"
				|| error.diagnostic.message.indexOf('Conflicting inherited interface instantiations for "Root"') < 0)
				throw error;
		}
		if (modularDiamond.exportIdentityState().compare(modularDiamondBaseline) != 0)
			throw "Rejected cross-module generic diamond changed committed compiler identity";
		Frontend.compile("class Parent { } class Child extends Parent { } function consume(value:Parent):Int { return 42; } function main():Int { return consume(new Child()); }");
		Frontend.compile("class Counter { public function new() { } function value():Int return 42; public function read():Int return value(); } function main():Int return new Counter().read();");
		Frontend.compile("class Counter { var value:Int = 40; public function new() { value += 2; } public function read():Int return value; } function main():Int return new Counter().read();");
		Frontend.compile("class Parent { public function new(value:Int) { } } class Child extends Parent { public function new() { super(42); } } function main():Int { var child = new Child(); return 42; }");
		Frontend.compile("typedef Score = Int; interface Rated { function rate(value:Score):Score; } class Item implements Rated { public function rate(value:Int):Int { return value; } } function main():Int { return new Item().rate(42); }");
		var semanticSignatureCompiler = new Compiler();
		semanticSignatureCompiler.update("Main.hx",
			"typedef Score = Int; function consume(value:Score):Score { return value; } function main():Int { return consume(42); }");
		semanticSignatureCompiler.compile("Main");
		semanticSignatureCompiler.update("Main.hx",
			"typedef Score = Int; function consume(value:Int):Int { return value; } function main():Int { return consume(42); }");
		if (semanticSignatureCompiler.compile("Main").requiresReload)
			throw "Alias-equivalent function spelling changed the semantic ABI";
		var semanticFieldCompiler = new Compiler();
		semanticFieldCompiler.update("Main.hx", "typedef Score = Int; class Item { public var score:Score; } function main():Int { return 42; }");
		semanticFieldCompiler.compile("Main");
		semanticFieldCompiler.update("Main.hx", "typedef Score = Int; class Item { public var score:Int; } function main():Int { return 42; }");
		if (semanticFieldCompiler.compile("Main").requiresReload)
			throw "Alias-equivalent field spelling changed the semantic layout";
		Frontend.compile("function main():Int { var value = 40; var read = () -> { var value = 2; return value; }; return read() + value; }");
		Frontend.compile("function main():Int { var value = 40; var outer = () -> { var inner = () -> { return value + 2; }; return inner(); }; return outer(); }");
		Frontend.compile("function main():Int { var left = 20, right:Int = 22; return left + right; }");
		Frontend.compile("function main():Int { var value:Int; if (true) value = 40; else value = 2; return value; }");
		Frontend.compile("function main():Int { var value:Int; switch (1) { case 1: value = 40; default: value = 2; } return value; }");
		Frontend.compile('function main():Int { var value:Int; try { value = 42; } catch (error:Dynamic) { throw "failed"; } return value; }');
		Frontend.compile('function main():Int { while (true) { var value:Int; try { value = 42; } catch (error:Dynamic) { break; } return value; } return 0; }');
		Frontend.compile("class Math { public static function answer():Int return 42; } function main():Int return Math.answer();");
		Frontend.compile('class Constants { public static inline final ANSWER = 42; static inline final LABEL = "answer"; static final VALUES = new Array<Int>(0); } function main():Int return Constants.ANSWER;');
		Frontend.compile('typedef Pair = { final left:Int; final right:Int; }; function sum(pair:Pair):Int return pair.left + pair.right; function main():Int return sum({left: 20, right: 22});');
		Frontend.compile('typedef Entry = {name:String, ?count:Int}; function read(entry:Entry):String return entry.name; function main():Int return 0;');
		var genericAst = new Parser(new Lexer(new SourceFile("generic.hx", "function identity<T>(value:T):T return value;")).tokenize()).parseProgram();
		if (genericAst.functions[0].typeParameters == null || genericAst.functions[0].typeParameters.join(",") != "T")
			throw "Generic function type parameters were not preserved";
		expectParserError("function invalid<T,T>(value:T):T return value;", 'Duplicate type parameter "T"');
		Frontend.compile('function identity<T>(value:T):T return value; function first<T>(values:Array<T>):T return values[0]; function main():Int { var values = new Array<Int>(1); values[0] = 42; return identity(first(values)); }');
		Frontend.compile('class GenericMethods { public static function identity<T>(value:T):T return value; public static function answer():Int return identity(42); } function main():Int return GenericMethods.answer();');
		var shapedGenericProgram = new Parser(new Lexer(new SourceFile("generic-shapes.hx",
			'class Box {} function identity<T>(value:T):T return value; function main():Int { identity("text"); identity(new Box()); return identity(42); }'))
			.tokenize()).parseProgram(),
			shapedGeneric = Typer.type(shapedGenericProgram),
			identityBodies = [for (fn in shapedGeneric.functions) if (fn.genericOrigin == "identity") fn];
		if (identityBodies.length != 2)
			throw "Generic reference instantiations did not share one representation body";
		var identityShapes = [for (fn in identityBodies) SemanticSignature.type(fn.typeArguments[0])];
		identityShapes.sort(Reflect.compare);
		if (identityShapes.join(",") != "Dynamic,Int")
			throw "Generic bodies were not partitioned by runtime representation";
		var layoutGenericProgram = new Parser(new Lexer(new SourceFile("generic-layout.hx",
			"function first<T>(values:Array<T>):T return values[0]; function main():Int { var values = new Array<Int>(1); values[0] = 42; return first(values); }"))
			.tokenize()).parseProgram(),
			layoutGeneric = Typer.type(layoutGenericProgram);
		if ([for (fn in layoutGeneric.functions) if (fn.name.indexOf("[layout]") >= 0) fn].length == 0)
			throw "Nested generic representation did not select the layout policy";
		var incrementalGeneric = new Compiler();
		incrementalGeneric.update("Main.hx", 'class Box {} function identity<T>(value:T):T return value; function main():Int { identity("text"); return 42; }');
		var firstGenericBuild = incrementalGeneric.compile("Main"),
			firstGenericBodies = [
				for (fn in firstGenericBuild.ir.functions)
					if (StringTools.startsWith(fn.name, "$generic:")) fn.name
			];
		incrementalGeneric.update("Main.hx",
			'class Box {} function identity<T>(value:T):T return value; function main():Int { identity(new Box()); return 42; }');
		var sharedShapeBuild = incrementalGeneric.compile("Main"),
			sharedGenericBodies = [
				for (fn in sharedShapeBuild.ir.functions)
					if (StringTools.startsWith(fn.name, "$generic:")) fn.name
			];
		firstGenericBodies.sort(Reflect.compare);
		sharedGenericBodies.sort(Reflect.compare);
		if (sharedShapeBuild.requiresReload || firstGenericBodies.join(",") != sharedGenericBodies.join(","))
			throw "Equivalent generic reference shapes did not preserve incremental identity";
		var specializationRegistry = new GenericSpecializationRegistry(),
			initialSpecialization = specializationRegistry.request("identity", [compiler.types.Type.CompilerType.TDynamic]),
			restoredRegistry = new GenericSpecializationRegistry(specializationRegistry.exportState()),
			restoredSpecialization = restoredRegistry.request("identity", [compiler.types.Type.CompilerType.TDynamic]);
		if (!initialSpecialization.isNew || restoredSpecialization.isNew || restoredSpecialization.name != initialSpecialization.name)
			throw "Generic specialization identity did not survive registry persistence";
		if (initialSpecialization.name.indexOf("[legacy]") < 0 || firstGenericBodies[0].indexOf("[shape]") < 0)
			throw "Generic specialization policy was not encoded in stable identity";
		var corruptSpecializations = new haxe.io.BytesOutput();
		corruptSpecializations.bigEndian = false;
		corruptSpecializations.writeString("GSR");
		corruptSpecializations.writeByte(1);
		corruptSpecializations.writeInt32(2);
		for (key in ["first", "second"]) {
			var keyBytes = haxe.io.Bytes.ofString(key),
				nameBytes = haxe.io.Bytes.ofString("collision");
			corruptSpecializations.writeInt32(keyBytes.length);
			corruptSpecializations.write(keyBytes);
			corruptSpecializations.writeInt32(nameBytes.length);
			corruptSpecializations.write(nameBytes);
		}
		try {
			new GenericSpecializationRegistry(corruptSpecializations.getBytes());
			throw "Generic specialization registry accepted colliding restored names";
		} catch (error:String) {
			if (error != "Generic specialization name collision")
				throw error;
		}
		var resumedGeneric = new Compiler(incrementalGeneric.exportIdentityState());
		resumedGeneric.update("Main.hx", 'class Box {} function identity<T>(value:T):T return value; function main():Int { identity(new Box()); return 42; }');
		var resumedGenericBuild = resumedGeneric.compile("Main"),
			resumedGenericBodies = [
				for (fn in resumedGenericBuild.ir.functions)
					if (StringTools.startsWith(fn.name, "$generic:")) fn.name
			];
		resumedGenericBodies.sort(Reflect.compare);
		if (resumedGenericBuild.requiresReload || resumedGenericBodies.join(",") != sharedGenericBodies.join(","))
			throw "Generic specialization identity did not survive compiler restart";
		var pruningCompiler = new Compiler();
		pruningCompiler.update("Library.hx", "class Library { public static function identity<T>(value:T):T return value; }");
		pruningCompiler.update("Main.hx", "import Library; function main():Int return Library.identity(42);");
		pruningCompiler.compile("Main");
		pruningCompiler.update("Main.hx", "function main():Int return 42;");
		var prunedBuild = pruningCompiler.compile("Main");
		for (fn in prunedBuild.ir.functions)
			if (StringTools.startsWith(fn.name, "$generic:") && fn.name.indexOf("identity") >= 0)
				throw "Unreachable module retained a stale generic specialization";
		Sys.println("PASS: generic specialization identity survives compiler restart");
		Frontend.compile('enum Value<T> { Value(value:T); } function intValue(value:Value<Int>):Int return switch value { case Value(item): item; }; function stringValue(value:Value<String>):String return switch value { case Value(item): item; }; function main():Int return intValue(Value(40)) + stringValue(Value("ok")).length;');
		expectCompileError('function choose<T>(left:T, right:T):T return left; function main():Int return choose(42, "wrong");',
			'Conflicting types inferred for generic parameter "T"');
		expectCompileError('typedef Invalid = { value:Int; value:String; }; function main():Int return 0;', 'Duplicate anonymous field "value"');
		expectCompileError('typedef Pair = {left:Int, right:Int}; function consume(pair:Pair):Int return pair.left; function main():Int return consume({left: 42});',
			'Missing object field "right"');
		Frontend.compile("function main():Int { var convert:(Int) -> Dynamic = (value:Int) -> { return value; }; convert(42); return 42; }");
		Frontend.compile("function main():Int { var convert:(Int) -> Int = (value) -> { return value; }; return convert(42); }");
		expectCompileError("class Box { public var value:Int; } function main():Int { var box:Null<Box> = new Box(); var clear = () -> { box = null; }; if (box != null) { clear(); return box.value; } return 0; }",
			'Field "value" requires an object');
		expectCompileError("class Box { public var value:Int; } function main():Int { var box:Null<Box> = new Box(); if (box != null) { box = null; return box.value; } return 0; }",
			'Field "value" requires an object');
		var captureProgram = new Parser(new Lexer(new SourceFile("capture.hx",
			"function main():Int { var value = 40; var read = () -> { return value + 2; }; return read(); }")).tokenize()).parseProgram(),
			captureTyped = Typer.type(captureProgram),
			captureObjects = IrGenerator.objectsFrom(captureTyped);
		if (captureTyped.classes.length != 0 || captureTyped.closurePlan.environments.length != 1)
			throw "Semantic typing manufactured a runtime helper class";
		if ([for (object in captureObjects) object.name].indexOf(captureTyped.closurePlan.environments[0].name) < 0)
			throw "Lowering did not materialize the capture environment";
		var exceptionStorage = Typer.type(new Parser(new Lexer(new SourceFile("exception-storage.hx",
			"function main():Int { var value = 1; try { value = 42; throw \"stop\"; } catch (error:String) { return value; } }")).tokenize()).parseProgram());
		if (exceptionStorage.closurePlan.storage.length != 1
			|| exceptionStorage.closurePlan.storage[0].kind != compiler.types.TypedAst.CellStorageKind.ExceptionEdge)
			throw "Exception-edge storage was confused with mutable capture storage";
		Sys.println("PASS: declaration resolution rejects unknown types and cycles and resolves semantic signatures");
		var classProgram = new Parser(new Lexer(new SourceFile("Box.hx",
			"package demo; class Box { public final value:Int; public var offset(get, never):Int; public function new(value:Int) { } public function get():Int { return 42; } function get_offset():Int { return value; } } function main():Int { return 42; }"))
			.tokenize()).parseProgram();
		if (classProgram.classes.length != 1
			|| classProgram.classes[0].fields[0].name != "value"
			|| classProgram.classes[0].fields[1].readAccess != compiler.syntax.Ast.AstFieldAccess.GetAccess
			|| classProgram.classes[0].fields[1].writeAccess != compiler.syntax.Ast.AstFieldAccess.NeverAccess
			|| classProgram.classes[0].methods.length != 3
			|| classProgram.classes[0].methods[0].name != "new")
			throw "Minimal class declarations were not preserved in the AST";
		var typedClass = Typer.type(classProgram);
		if (typedClass.classes.length != 1
			|| typedClass.classes[0].fields[0].type != compiler.types.Type.CompilerType.TInt
			|| typedClass.classes[0].fields[1].readAccess != compiler.syntax.Ast.AstFieldAccess.GetAccess
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
		if (interfaceProgram.interfaces.length != 1
			|| compiler.semantic.ModuleCanonicalizer.astTypeName(interfaceProgram.classes[0].interfaces[0]) != "Plugin")
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
		var importedEnumCompiler = new Compiler();
		importedEnumCompiler.update("Kinds.hx", "enum Choice { Bytes(value:Int); Empty; }");
		importedEnumCompiler.update("Data.hx", "class Bytes {}");
		importedEnumCompiler.update("Main.hx",
			"import Kinds.Choice; import Data.Bytes; function consume(value:Bytes):Int return 0; function main():Int { var payload:Bytes = new Bytes(); var choice:Choice = Bytes(42); return consume(payload) + switch choice { case Bytes(value): value; case Empty: 0; }; }");
		importedEnumCompiler.compile("Main");
		var ambiguousConstructorCompiler = new Compiler();
		ambiguousConstructorCompiler.update("First.hx", "enum FirstChoice { Same(value:Int); }");
		ambiguousConstructorCompiler.update("Second.hx", "enum SecondChoice { Same(value:String); }");
		ambiguousConstructorCompiler.update("Main.hx",
			"import First.FirstChoice; import Second.SecondChoice; function main():Int { var first:FirstChoice = Same(42); var second:SecondChoice = Same(\"value\"); return switch first { case Same(value): value; }; }");
		ambiguousConstructorCompiler.compile("Main");
		var staticClass = Frontend.compile("class Math { public static function add(a:Int, b:Int):Int { return a + b; } } function main():Int { return Math.add(20, 22); }");
		var foundStatic = false;
		for (fn in staticClass.functions)
			if (fn.name == "Math.add")
				foundStatic = true;
		if (!foundStatic)
			throw "Static class method was not lowered as a callable function";
		Frontend.compile("class Box { public function get():Int { return 42; } } class Holder { public static var box:Box = new Box(); public static function read():Int { return box.get(); } } function main():Int { return Holder.read(); }");
		Sys.println("PASS: static object fields retain receiver types for instance calls");
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
			Frontend.compileFile(new SourceFile("broken.hx", "function main():Int { return ~; }"));
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

	static function expectParserError(source:String, expected:String):Void {
		try {
			new Parser(new Lexer(new SourceFile("invalid.hx", source)).tokenize()).parseProgram();
			throw 'parser accepted invalid source; expected "$expected"';
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

	static function collectInstructionValues(value:Dynamic, values:Map<Int, compiler.ir.Ir.IrValue>):Void {
		if (Std.isOfType(value, compiler.ir.Ir.IrValue)) {
			var irValue:compiler.ir.Ir.IrValue = cast value;
			values.set(irValue.id, irValue);
		} else if (Std.isOfType(value, Array))
			for (item in (cast value : Array<Dynamic>))
				collectInstructionValues(Reflect.hasField(item, "value") ? Reflect.field(item, "value") : item, values);
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
