package compiler.hl;

typedef HlPatch = {
    final moduleId:haxe.io.Bytes;
    final baseRevision:Int;
    final revision:Int;
    final baseInts:Int; final baseFloats:Int; final baseStrings:Int; final baseTypes:Int;
    final intPrefixHash:Int; final floatPrefixHash:Int; final stringPrefixHash:Int; final typePrefixHash:Int;
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
    final relocations:Array<{instruction:Int, stableId:Int}>;
}

typedef HlPatchInstruction = {
    final opcode:Int;
    final operands:Array<Int>;
}
