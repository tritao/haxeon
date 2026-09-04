import compiler.hl.HlCode;
import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.HlFunction;
import compiler.hl.HlFunction.HlInstruction;
import compiler.hl.HlType;
import compiler.hl.HlWriter;
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
        try {
            HlWriter.encode(invalid);
            throw "writer accepted a missing entry point";
        } catch (error:String) {
            if (error != "Entry point 1 is not a function")
                throw error;
        }
        Sys.println("PASS: malformed module is rejected before serialization");
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
