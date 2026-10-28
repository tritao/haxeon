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

	/** Globals the running module has; the patch's `globals` follow them. Zero when the patch adds none. */
	final baseGlobals:Int;

	final intPrefixHash:Int;
	final floatPrefixHash:Int;
	final stringPrefixHash:Int;
	final typePrefixHash:Int;
	final globalPrefixHash:Int;
	final ints:Array<Int>;
	final floats:Array<Float>;
	final strings:Array<String>;
	final types:Array<HlTypeDef>;
	final functions:Array<HlPatchFunction>;
	final addedFunctions:Array<HlPatchAddedFunction>;
	final globals:Array<HlPatchGlobal>;
	final debugFiles:Array<String>;
	final sourceSnapshots:Array<{sourceHash:Int, content:haxe.io.Bytes}>;
}

/** One replacement function addressed by stable identity after relocation. */
typedef HlPatchFunction = {
	final type:Int;
	final functionIndex:Int;
	final registers:Array<Int>;
	final instructions:Array<HlPatchInstruction>;
	final relocations:Array<{instruction:Int, stableId:Int}>;
	final debug:Array<{
		file:Int,
		line:Int,
		column:Int,
		endLine:Int,
		endColumn:Int,
		sourceHash:Int,
		start:Int,
		end:Int,
		flags:Int
	}>;
}

/** A function the patch adds to the running module, in the next free slot. */
typedef HlPatchAddedFunction = {
	final stableId:Int;
	final functionIndex:Int;
	final type:Int;
	final name:String;
}

/** A global the patch adds, with the constant it holds: the fields of its object, as indices into the module's tables. */
typedef HlPatchGlobal = {
	final type:Int;

	/** False for the null value slot of a new object type, which has no fields. */
	final constant:Bool;

	final fields:Array<Int>;
}

/** Decoded numeric HashLink opcode and its wire operands. */
typedef HlPatchInstruction = {
	final opcode:Int;
	final operands:Array<Int>;
}
