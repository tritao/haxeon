package compiler.hl.patch;

import compiler.hl.HlCode.HlTypeDef;

/** Decoded HLP transaction, including expected live prefixes and replacements. */
typedef HlPatch = {
	final moduleId:haxe.io.Bytes;
	final baseRevision:Int;
	final revision:Int;
	final baseInts:Int;
	final baseFloats:Int;
	final baseStrings:Int;
	final baseTypes:Int;
	final intPrefixHash:Int;
	final floatPrefixHash:Int;
	final stringPrefixHash:Int;
	final typePrefixHash:Int;
	final ints:Array<Int>;
	final floats:Array<Float>;
	final strings:Array<String>;
	final types:Array<HlTypeDef>;
	final functions:Array<HlPatchFunction>;
}

/** One replacement function addressed by stable identity after relocation. */
typedef HlPatchFunction = {
	final type:Int;
	final functionIndex:Int;
	final registers:Array<Int>;
	final instructions:Array<HlPatchInstruction>;
	final relocations:Array<{instruction:Int, stableId:Int}>;
}

/** Decoded numeric HashLink opcode and its wire operands. */
typedef HlPatchInstruction = {
	final opcode:Int;
	final operands:Array<Int>;
}
