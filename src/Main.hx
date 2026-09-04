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
        var code = makeFibProgram();
        File.saveBytes(path, HlWriter.encode(code));
        Sys.println('wrote $path');
    }

    static function makeFibProgram():HlCode {
        var code = new HlCode();
        code.ints = [1, 2, 10];
        code.strings = ["std", "sys_exit"];
        code.types = [
            Simple(HlType.Void),            // 0
            Simple(HlType.I32),             // 1
            Function([1], 1),               // 2: (I32) -> I32
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
            new HlFunction(2, 1, [1, 1, 1, 1, 1, 1, 1, 1], [
                LoadInt(1, 0),
                JumpSignedLessOrEqual(0, 1, "base_case"),
                LoadInt(4, 1),
                Sub(2, 0, 1),
                Call1(3, 1, 2),
                Sub(5, 0, 4),
                Call1(6, 1, 5),
                Add(7, 3, 6),
                Return(7),
                Label("base_case"),
                Return(0),
            ]),
            new HlFunction(4, 2, [1, 1, 0], [
                LoadInt(0, 2),
                Call1(1, 1, 0),
                Call1(2, 0, 1),
                Return(2),
            ]),
        ];
        code.entryPoint = 2;
        return code;
    }
}
