package compiler.hl;

typedef HlPatch = {
    final baseRevision:Int;
    final revision:Int;
    final ints:Array<Int>;
    final floats:Array<Float>;
    final strings:Array<String>;
    final types:Array<HlCode.HlTypeDef>;
    final functions:Array<HlPatchFunction>;
}

typedef HlPatchFunction = {
    final type:Int;
    final functionIndex:Int;
    final registers:Array<Int>;
    final instructions:Array<HlPatchInstruction>;
}

typedef HlPatchInstruction = {
    final opcode:Int;
    final operands:Array<Int>;
}
