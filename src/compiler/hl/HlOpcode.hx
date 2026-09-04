package compiler.hl;

/** Opcode numbers are ABI: their order follows HashLink's src/opcodes.h. */
enum abstract HlOpcode(Int) from Int to Int {
    var Mov = 0;
    var Int = 1;
    var Add = 7;
    var Call1 = 25;
    var Call2 = 26;
    var Ret = 67;
}
