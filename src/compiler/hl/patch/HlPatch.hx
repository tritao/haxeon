package compiler.hl.patch;

import compiler.hl.HlCode.HlTypeDef;

/** Identity projection used by runtime publication policy. */
typedef HlPatchEnvelope = {
	final moduleId:haxe.io.Bytes;
	final baseRevision:Int;
	final revision:Int;
	final functionStableIds:Array<Int>;
	final relocationStableIds:Array<Int>;
}

typedef HlPatchDebugLocation = {
	final file:Int;
	final line:Int;
	final column:Int;
	final endLine:Int;
	final endColumn:Int;
	final sourceHash:Int;
	final start:Int;
	final end:Int;
	final flags:Int;
}

typedef HlPatchSourceSnapshot = {
	final sourceHash:Int;
	final content:haxe.io.Bytes;
}

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
	public final sourceSnapshots:Array<HlPatchSourceSnapshot>;

	public function new(moduleId:haxe.io.Bytes, baseRevision:Int, revision:Int, baseInts:Int, baseFloats:Int, baseStrings:Int, baseTypes:Int,
			intPrefixHash:Int, floatPrefixHash:Int, stringPrefixHash:Int, typePrefixHash:Int, ints:Array<Int>, floats:Array<Float>, strings:Array<String>,
			types:Array<HlTypeDef>, functions:Array<HlPatchFunction>, debugFiles:Array<String>, sourceSnapshots:Array<HlPatchSourceSnapshot>) {
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

	/** Project this decoded patch into the stable-identity policy view. */
	public function envelope():HlPatchEnvelope {
		var functionStableIds = [for (fn in functions) fn.functionIndex],
			relocationStableIds:Array<Int> = [];
		for (fn in functions)
			for (relocation in fn.relocations)
				relocationStableIds.push(relocation.stableId);
		return {
			moduleId: moduleId,
			baseRevision: baseRevision,
			revision: revision,
			functionStableIds: functionStableIds,
			relocationStableIds: relocationStableIds
		};
	}

	/** Deep-copy the decoded model before transferring it to another owner. */
	public function copy():HlPatch {
		return new HlPatch(moduleId.sub(0, moduleId.length), baseRevision, revision, baseInts, baseFloats, baseStrings, baseTypes, intPrefixHash,
			floatPrefixHash, stringPrefixHash, typePrefixHash, ints.copy(), floats.copy(), strings.copy(), [for (type in types) copyType(type)],
			[for (fn in functions) fn.copy()], debugFiles.copy(), [
				for (snapshot in sourceSnapshots)
					{
						sourceHash: snapshot.sourceHash,
						content: snapshot.content.sub(0, snapshot.content.length)
					}
			]);
	}

	static function copyType(type:HlTypeDef):HlTypeDef {
		return switch type {
			case Simple(kind): Simple(kind);
			case Parameterized(kind, parameter): Parameterized(kind, parameter);
			case Abstract(name): Abstract(name);
			case Function(arguments, result): Function(arguments.copy(), result);
			case Method(arguments, result): Method(arguments.copy(), result);
			case Object(name, base, global, fields, methods, bindings):
				Object(name, base, global, [for (field in fields) {name: field.name, type: field.type}], [
					for (method in methods)
						{name: method.name, functionIndex: method.functionIndex, prototype: method.prototype}
				], bindings.copy());
			case Structure(name, global, fields, methods, bindings):
				Structure(name, global, [for (field in fields) {name: field.name, type: field.type}], [
					for (method in methods)
						{name: method.name, functionIndex: method.functionIndex, prototype: method.prototype}
				], bindings.copy());
			case Virtual(fields): Virtual([for (field in fields) {name: field.name, type: field.type}]);
			case Enum(name, global, constructors): Enum(name, global, [
					for (constructor in constructors)
						{name: constructor.name, params: constructor.params.copy()}
				]);
		};
	}
}

/** One replacement function addressed by stable identity after relocation. */
class HlPatchFunction {
	public final type:Int;
	public final functionIndex:Int;
	public final slot:Int;
	public final registers:Array<Int>;
	public final instructions:Array<HlPatchInstruction>;
	public final relocations:Array<{instruction:Int, stableId:Int}>;
	public final debug:Array<HlPatchDebugLocation>;

	public function new(type:Int, functionIndex:Int, slot:Int, registers:Array<Int>, instructions:Array<HlPatchInstruction>,
			relocations:Array<{instruction:Int, stableId:Int}>, ?debug:Array<HlPatchDebugLocation>) {
		this.type = type;
		this.functionIndex = functionIndex;
		this.slot = slot;
		this.registers = registers;
		this.instructions = instructions;
		this.relocations = relocations;
		this.debug = debug == null ? [] : debug;
	}

	public function copy():HlPatchFunction {
		return new HlPatchFunction(type, functionIndex, slot, registers.copy(), [for (instruction in instructions) instruction.copy()], [
			for (relocation in relocations)
				{
					instruction: relocation.instruction,
					stableId: relocation.stableId
				}
		], [
			for (location in debug)
				{
					file: location.file,
					line: location.line,
					column: location.column,
					endLine: location.endLine,
					endColumn: location.endColumn,
					sourceHash: location.sourceHash,
					start: location.start,
					end: location.end,
					flags: location.flags
				}
		]);
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

	public function copy():HlPatchInstruction
		return new HlPatchInstruction(opcode, operands.copy());
}
