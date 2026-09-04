package compiler.hl;

import haxe.io.Bytes;
import haxe.io.BytesInput;
import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.HlPatch;

class HlPatchReader {
    public static function decode(bytes:Bytes):HlPatch {
        var input=new BytesInput(bytes);input.bigEndian=false;
        try {
            if(input.readString(3)!="HLP")throw "Invalid HLP magic";
            if(input.readByte()!=HlPatchWriter.VERSION)throw "Unsupported HLP version";
            var base=readUnsigned(input),revision=readUnsigned(input);if(revision<=base)throw "Invalid patch revision range";
            var baseInts=readUnsigned(input),ints=[for(_ in 0...readUnsigned(input))input.readInt32()];
            var baseFloats=readUnsigned(input),floats=[for(_ in 0...readUnsigned(input))input.readDouble()];
            var baseStrings=readUnsigned(input),strings=[for(_ in 0...readUnsigned(input))input.readString(readUnsigned(input))];
            var baseTypes=readUnsigned(input),types=[];for(_ in 0...readUnsigned(input))types.push(readType(input));
            var functions=[];for(_ in 0...readUnsigned(input)){var length=readUnsigned(input),end=input.position+length;functions.push(readFunction(input));if(input.position!=end)throw "Invalid patch function length";}
            if(input.position!=bytes.length)throw "Trailing HLP data";
            return {baseRevision:base,revision:revision,baseInts:baseInts,baseFloats:baseFloats,baseStrings:baseStrings,baseTypes:baseTypes,ints:ints,floats:floats,strings:strings,types:types,functions:functions};
        } catch(error:haxe.io.Eof) {throw "Truncated HLP data";}
    }
    static function readType(input:BytesInput):HlTypeDef {var tag=input.readByte();return if(tag==HlType.Fun){var n=input.readByte();Function([for(_ in 0...n)readIndex(input)],readIndex(input));}else Simple(cast tag);}
    static function readFunction(input:BytesInput):HlPatchFunction {
        var type=readIndex(input),index=readUnsigned(input),registerCount=readUnsigned(input),instructionCount=readUnsigned(input);
        var registers=[for(_ in 0...registerCount)readIndex(input)];
        var instructions=[];for(_ in 0...instructionCount){var opcode=input.readByte(),count=operandCount(opcode);instructions.push({opcode:opcode,operands:[for(_ in 0...count)readIndex(input)]});}
        return {type:type,functionIndex:index,registers:registers,instructions:instructions};
    }
    static function operandCount(op:Int):Int return switch op {case 1,3,58,67:2-(op==58||op==67?1:0);case 7,8,25,44:3-(op==44?1:0);case 24:2;case 26:4;case 48,51,56:3;default:throw 'Unsupported patch opcode $op';}
    static function readUnsigned(input:BytesInput):Int {var v=readIndex(input);if(v<0)throw "Negative unsigned HLP index";return v;}
    static function readIndex(input:BytesInput):Int {var first=input.readByte();if((first&0x80)==0)return first&0x7F;if((first&0x40)==0){var v=input.readByte()|((first&31)<<8);return(first&0x20)==0?v:-v;}var v=((first&31)<<24)|(input.readByte()<<16)|(input.readByte()<<8)|input.readByte();return(first&0x20)==0?v:-v;}
}
