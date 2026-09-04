import compiler.hl.HlCode;
import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.HlFunction;
import compiler.hl.HlFunction.HlInstruction;
import compiler.hl.HlOpcode;
import compiler.hl.HlType;
import compiler.hl.HlWriter;
import sys.io.File;

class Main {
    static function main():Void {
        var path = Sys.args().length == 0 ? "out/handmade.hl" : Sys.args()[0];
        var code = makeExit42Program();
        File.saveBytes(path, HlWriter.encode(code));
        Sys.println('wrote $path');
    }

    static function makeExit42Program():HlCode {
        var code = new HlCode();
        code.ints = [42];
        code.strings = ["std", "sys_exit"];
        code.types = [
            Simple(HlType.Void),            // 0
            Simple(HlType.I32),             // 1
            Function([1], 0),               // 2: (I32) -> Void
            Function([], 0),                // 3: () -> Void
        ];
        code.natives = [{
            library: 0,
            name: 1,
            type: 2,
            functionIndex: 0,
        }];
        code.functions = [new HlFunction(3, 1, [1, 0], [
            new HlInstruction(HlOpcode.Int, [0, 0]),
            new HlInstruction(HlOpcode.Call1, [1, 0, 0]),
            new HlInstruction(HlOpcode.Ret, [1]),
        ])];
        code.entryPoint = 1;
        return code;
    }
}
