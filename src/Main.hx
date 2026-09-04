import compiler.hl.HlCode;
import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.HlFunction;
import compiler.hl.HlFunction.HlInstruction;
import compiler.hl.HlType;
import compiler.hl.HlWriter;
import sys.io.File;

class Main {
    static function main():Void {
        var path = Sys.args().length == 0 ? "out/handmade.hl" : Sys.args()[0];
        var code = makeAddProgram();
        File.saveBytes(path, HlWriter.encode(code));
        Sys.println('wrote $path');
    }

    static function makeAddProgram():HlCode {
        var code = new HlCode();
        code.ints = [20, 22];
        code.strings = ["std", "sys_exit"];
        code.types = [
            Simple(HlType.Void),            // 0
            Simple(HlType.I32),             // 1
            Function([1, 1], 1),            // 2: (I32, I32) -> I32
            Function([1], 0),               // 3: (I32) -> Void
            Function([], 0),                // 4: () -> Void
        ];
        code.natives = [{
            library: 0,
            name: 1,
            type: 3,
            functionIndex: 0,
        }];
        code.functions = [
            new HlFunction(2, 1, [1, 1, 1], [
                Add(2, 0, 1),
                Return(2),
            ]),
            new HlFunction(4, 2, [1, 1, 1, 0], [
                LoadInt(0, 0),
                LoadInt(1, 1),
                Call2(2, 1, 0, 1),
                Call1(3, 0, 2),
                Return(3),
            ]),
        ];
        code.entryPoint = 2;
        return code;
    }
}
