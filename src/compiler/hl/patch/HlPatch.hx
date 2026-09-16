package compiler.hl.patch;

import compiler.hl.HlCode.HlTypeDef;

/** Decoded HLP transaction, including expected live prefixes and replacements. */
class HlPatch {
	public final moduleId:haxe.io.Bytes;
	public final baseRevision:Int;
	public final revision:Int;
	public final baseInts:Int;
	public final baseFloats:Int;
	public final baseStrings:Int;
	public final baseTypes:Int;
	public final intPrefixHash:Int;
	public final floatPrefixHash:Int;
	public final stringPrefixHash:Int;
	public final typePrefixHash:Int;
	public final ints:Array<Int>;
	public final floats:Array<Float>;
	public final strings:Array<String>;
	public final types:Array<HlTypeDef>;
	public final functions:Array<HlPatchFunction>;
	public final debugFiles:Array<String>;
	public final sourceSnapshots:Array<{sourceHash:Int, content:haxe.io.Bytes}>;

	public function new(moduleId:haxe.io.Bytes, baseRevision:Int, revision:Int, baseInts:Int, baseFloats:Int, baseStrings:Int, baseTypes:Int,
			intPrefixHash:Int, floatPrefixHash:Int, stringPrefixHash:Int, typePrefixHash:Int, ints:Array<Int>, floats:Array<Float>, strings:Array<String>,
			types:Array<HlTypeDef>, functions:Array<HlPatchFunction>, debugFiles:Array<String>, sourceSnapshots:Array<{
			sourceHash:Int,
			content:haxe.io.Bytes
		}>) {
		this.moduleId = moduleId;
		this.baseRevision = baseRevision;
		this.revision = revision;
		this.baseInts = baseInts;
		this.baseFloats = baseFloats;
		this.baseStrings = baseStrings;
		this.baseTypes = baseTypes;
		this.intPrefixHash = intPrefixHash;
		this.floatPrefixHash = floatPrefixHash;
		this.stringPrefixHash = stringPrefixHash;
		this.typePrefixHash = typePrefixHash;
		this.ints = ints;
		this.floats = floats;
		this.strings = strings;
		this.types = types;
		this.functions = functions;
		this.debugFiles = debugFiles;
		this.sourceSnapshots = sourceSnapshots;
		}
}

/** One replacement function addressed by stable identity after relocation. */
class HlPatchFunction {
	public final type:Int;
	public final functionIndex:Int;
	public final registers:Array<Int>;
	public final instructions:Array<HlPatchInstruction>;
	public final relocations:Array<{instruction:Int, stableId:Int}>;
	public final debug:Array<{
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

	public function new(type:Int, functionIndex:Int, registers:Array<Int>, instructions:Array<HlPatchInstruction>,
			relocations:Array<{instruction:Int, stableId:Int}>) {
		this.type = type;
		this.functionIndex = functionIndex;
		this.registers = registers;
		this.instructions = instructions;
		this.relocations = relocations;
		debug = [];
	}
}

/** Decoded numeric HashLink opcode and its wire operands. */
class HlPatchInstruction {
	public final opcode:Int;
	public final operands:Array<Int>;

	public function new(opcode:Int, operands:Array<Int>) {
		this.opcode = opcode;
		this.operands = operands;
	}
}
