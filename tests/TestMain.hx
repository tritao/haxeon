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
import compiler.ir.SsaBuilder;
import compiler.ir.Cfg.CfgInstruction;
import compiler.ir.Cfg.CfgBlock;
import compiler.ir.Cfg.CfgFunction;
import compiler.ir.Cfg.CfgValue;
import compiler.ir.CfgVerifier;
import compiler.Lexer;
import compiler.Parser;
import compiler.types.Typer;
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
		patchCode.functions = [
			new HlFunction(2, 0, [1], [LoadInt(0, 0), Return(0)]),
			new HlFunction(2, 1, [1], [LoadInt(0, 0), Return(0)]),
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
		if (patch.functions[0].instructions.length != 2 || patch.functions[0].instructions[0].opcode != HlOpcode.Int)
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
		expectCompileError('function main():Int { return 1; var unreachable = 2; }', 'Unreachable statement');
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
