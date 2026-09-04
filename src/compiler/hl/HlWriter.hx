package compiler.hl;

import haxe.io.Bytes;
import haxe.io.BytesOutput;
import haxe.io.Encoding;
import compiler.hl.HlCode.HlTypeDef;

class HlWriter {
    final output:BytesOutput;

    public function new() {
        output = new BytesOutput();
        output.bigEndian = false;
    }

    public static function encode(code:HlCode):Bytes {
        var writer = new HlWriter();
        writer.writeCode(code);
        return writer.output.getBytes();
    }

    function writeCode(code:HlCode):Void {
        output.writeString("HLB", Encoding.UTF8);
        output.writeByte(HlCode.VERSION);
        writeUnsignedIndex(0); // flags: no debug information
        writeUnsignedIndex(code.ints.length);
        writeUnsignedIndex(code.floats.length);
        writeUnsignedIndex(code.strings.length);
        writeUnsignedIndex(0); // byte blobs
        writeUnsignedIndex(code.types.length);
        writeUnsignedIndex(0); // globals
        writeUnsignedIndex(code.natives.length);
        writeUnsignedIndex(code.functions.length);
        writeUnsignedIndex(0); // constants
        writeUnsignedIndex(code.entryPoint);

        for (value in code.ints)
            output.writeInt32(value);
        for (value in code.floats)
            output.writeDouble(value);
        writeStrings(code.strings);
        output.writeInt32(0); // byte blob storage size

        for (type in code.types)
            writeType(type);
        for (native in code.natives) {
            writeIndex(native.library);
            writeIndex(native.name);
            writeIndex(native.type);
            writeUnsignedIndex(native.functionIndex);
        }
        for (fn in code.functions)
            writeFunction(fn);
    }

    function writeStrings(strings:Array<String>):Void {
        var data = new BytesOutput();
        var lengths = [];
        for (value in strings) {
            var bytes = Bytes.ofString(value, Encoding.UTF8);
            lengths.push(bytes.length);
            data.write(bytes);
            data.writeByte(0);
        }
        var bytes = data.getBytes();
        output.writeInt32(bytes.length);
        output.write(bytes);
        for (length in lengths)
            writeUnsignedIndex(length);
    }

    function writeType(type:HlTypeDef):Void {
        switch type {
            case Simple(kind):
                output.writeByte(kind);
            case Function(arguments, result):
                if (arguments.length > 255)
                    throw "HL function types support at most 255 arguments";
                output.writeByte(HlType.Fun);
                output.writeByte(arguments.length);
                for (argument in arguments)
                    writeIndex(argument);
                writeIndex(result);
        }
    }

    function writeFunction(fn:HlFunction):Void {
        writeIndex(fn.type);
        writeUnsignedIndex(fn.functionIndex);
        writeUnsignedIndex(fn.registers.length);
        writeUnsignedIndex(fn.opcodes.length);
        for (type in fn.registers)
            writeIndex(type);
        for (instruction in fn.opcodes) {
            output.writeByte(instruction.opcode);
            for (operand in instruction.operands)
                writeIndex(operand);
        }
    }

    function writeUnsignedIndex(value:Int):Void {
        if (value < 0)
            throw 'Expected unsigned index, got $value';
        writeIndex(value);
    }

    /** Inverse of HashLink's signed variable-width hl_read_index. */
    function writeIndex(value:Int):Void {
        var negative = value < 0;
        var magnitude = negative ? -value : value;
        if (magnitude < 0x80 && !negative) {
            output.writeByte(magnitude);
        } else if (magnitude < 0x2000) {
            output.writeByte(0x80 | (negative ? 0x20 : 0) | (magnitude >> 8));
            output.writeByte(magnitude & 0xFF);
        } else if (magnitude < 0x20000000) {
            output.writeByte(0xC0 | (negative ? 0x20 : 0) | (magnitude >> 24));
            output.writeByte((magnitude >> 16) & 0xFF);
            output.writeByte((magnitude >> 8) & 0xFF);
            output.writeByte(magnitude & 0xFF);
        } else {
            throw 'HL index is out of range: $value';
        }
    }
}
