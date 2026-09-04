import compiler.hl.HlCode;
import compiler.Frontend;
import compiler.Diagnostic.CompileError;
import compiler.Source.SourceFile;
import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.HlFunction;
import compiler.hl.HlFunction.HlInstruction;
import compiler.hl.HlType;
import compiler.hl.HlWriter;
import compiler.ir.HlLower;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import haxe.io.BytesInput;

class TestMain {
    static function main():Void {
        var values = [
            -0x1FFFFFFF, -0x2000, -0x1FFF, -0x80, -1,
            0, 1, 0x7F, 0x80, 0x1FFF, 0x2000, 0x1FFFFFFF,
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
        unknownLabel.functions = [new HlFunction(2, 0, [1, 1], [
            JumpSignedLessOrEqual(0, 1, "missing"),
            Return(0),
        ])];
        expectError(unknownLabel, 'Unknown label "missing" in function 0');

        var duplicateLabel = baseControlFlowModule();
        duplicateLabel.functions = [new HlFunction(2, 0, [1], [
            Label("same"),
            Label("same"),
            Return(0),
        ])];
        expectError(duplicateLabel, 'Duplicate label "same" in function 0');
        Sys.println("PASS: malformed module is rejected before serialization");

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
        expectCompileError('function main():Int { if (1 < 2) return 1; }',
            'Function main does not return on every path');
        expectCompileError('function main():Int { if (1) return 1; else return 2; }',
            'If condition must be Bool');
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
        } catch (error:String) {
            if (error != expected) throw error;
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
        var value = ((first & 31) << 24)
            | (input.readByte() << 16)
            | (input.readByte() << 8)
            | input.readByte();
        return (first & 0x20) == 0 ? value : -value;
    }
}
