import compiler.hl.HlWriter;
import compiler.ir.HlLower;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.ir.Ir.IrValue;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import sys.io.File;

class Main {
    static function main():Void {
        var path = Sys.args().length == 0 ? "out/handmade.hl" : Sys.args()[0];
        var code = HlLower.lower(makeFibProgram());
        File.saveBytes(path, HlWriter.encode(code));
        Sys.println('wrote $path');
    }

    static function makeFibProgram():IrProgram {
        var program = new IrProgram("main");
        program.natives.push({
            name: "exit",
            library: "std",
            symbol: "sys_exit",
            arguments: [IrType.I32],
            result: IrType.Void,
        });

        var n = new IrValue("n", IrType.I32);
        var fib = new IrBuilder();
        var one = fib.constInt(1);
        fib.branchLessOrEqual(n, one, "base_case");
        var two = fib.constInt(2);
        var nMinusOne = fib.sub(n, one);
        var first = fib.call("fib", [nMinusOne], IrType.I32);
        var nMinusTwo = fib.sub(n, two);
        var second = fib.call("fib", [nMinusTwo], IrType.I32);
        fib.returnValue(fib.add(first, second));
        fib.label("base_case");
        fib.returnValue(n);
        program.functions.push(new IrFunction("fib", [n], IrType.I32, fib.instructions));

        var main = new IrBuilder();
        var ten = main.constInt(10);
        var result = main.call("fib", [ten], IrType.I32);
        var exited = main.call("exit", [result], IrType.Void);
        main.returnValue(exited);
        program.functions.push(new IrFunction("main", [], IrType.Void, main.instructions));
        return program;
    }
}
