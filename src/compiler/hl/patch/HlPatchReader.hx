package compiler.hl.patch;

import haxe.io.Bytes;
import haxe.io.BytesInput;
import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.HlOpcode;
import compiler.hl.HlOpcodeSchema;
import compiler.hl.HlType;
import compiler.hl.patch.HlPatch.HlPatchAddedFunction;
import compiler.hl.patch.HlPatch.HlPatchFunction;
import compiler.hl.patch.HlPatch.HlPatchGlobal;
import compiler.hl.patch.HlPatch.HlPatchInstruction;

/** Strict HLP decoder used as the Haxe-side oracle for native patch validation. */
class HlPatchReader {
	public static function decode(bytes:Bytes):HlPatch {
		var input = new BytesInput(bytes);
		input.bigEndian = false;
		try {
			if (input.readString(3) != HlPatchFormat.MAGIC)
				throw "Invalid HLP magic";
			if (input.readByte() != HlPatchFormat.VERSION)
				throw "Unsupported HLP version";
			var moduleId = input.read(16),
				base = readUnsigned(input),
				revision = readUnsigned(input);
			if (revision <= base)
				throw "Invalid patch revision range";
			var baseInts = -1, baseFloats = -1, baseStrings = -1, baseTypes = -1, intPrefixHash = 0, floatPrefixHash = 0, stringPrefixHash = 0,
				typePrefixHash = 0, ints = [], floats = [], strings = [], types = [], functions = [], debugFiles = [], sourceSnapshots = [],
				haveDebug = false, haveSnapshots = false, haveAdded = false, addedFunctions:Array<HlPatchAddedFunction> = [], haveGlobals = false,
				baseGlobals = 0, globalPrefixHash = 0, globals:Array<HlPatchGlobal> = [];
			for (_ in 0...readUnsigned(input)) {
				var tag = input.readByte(),
					length = readUnsigned(input),
					end = input.position + length;
				if (end > bytes.length)
					throw "Truncated HLP data";
				switch tag {
					case 1:
						if (baseInts >= 0)
							throw "Duplicate HLP symbols section";
						intPrefixHash = input.readInt32();
						baseInts = readUnsigned(input);
						ints = [for (_ in 0...readUnsigned(input)) input.readInt32()];
						floatPrefixHash = input.readInt32();
						baseFloats = readUnsigned(input);
						floats = [for (_ in 0...readUnsigned(input)) input.readDouble()];
						stringPrefixHash = input.readInt32();
						baseStrings = readUnsigned(input);
						strings = [for (_ in 0...readUnsigned(input)) input.readString(readUnsigned(input))];
						typePrefixHash = input.readInt32();
						baseTypes = readUnsigned(input);
						for (_ in 0...readUnsigned(input))
							types.push(readType(input));
					case 2:
						if (functions.length > 0)
							throw "Duplicate HLP functions section";
						for (_ in 0...readUnsigned(input)) {
							var functionLength = readUnsigned(input),
								functionEnd = input.position + functionLength;
							functions.push(readFunction(input));
							if (input.position != functionEnd)
								throw "Invalid patch function length";
						}
					case 3:
						if (haveDebug)
							throw "Duplicate HLP debug section";
						haveDebug = true;
						debugFiles = [for (_ in 0...readUnsigned(input)) input.readString(readUnsigned(input))];
						var debugFunctions = readUnsigned(input),
							seen:Map<Int, Bool> = [];
						if (debugFunctions != functions.length)
							throw "HLP debug function count mismatch";
						for (_ in 0...debugFunctions) {
							var stableId = readUnsigned(input),
								found:Null<HlPatchFunction> = null;
							if (seen.exists(stableId))
								throw "Duplicate HLP function debug metadata";
							seen.set(stableId, true);
							for (fn in functions)
								if (fn.functionIndex == stableId)
									found = fn;
							if (found == null)
								throw "Unknown HLP debug function";
							var count = readUnsigned(input);
							if (count != found.instructions.length)
								throw "HLP debug opcode count mismatch";
							for (_ in 0...count) {
								var file = readUnsigned(input),
									line = readUnsigned(input),
									column = readUnsigned(input),
									endLine = readUnsigned(input),
									endColumn = readUnsigned(input),
									sourceHash = input.readInt32(),
									start = readIndex(input) - 1,
									end = readIndex(input) - 1,
									flags = readUnsigned(input),
									validRange = start == -1 && end == -1 || start >= 0 && end >= start;
								if (file >= debugFiles.length || line < 1 || column < 1 || endLine < line || endColumn < 1 || endLine == line
									&& endColumn < column || !validRange)
									throw "Invalid HLP debug location";
								found.debug.push({
									file: file,
									line: line,
									column: column,
									endLine: endLine,
									endColumn: endColumn,
									sourceHash: sourceHash,
									start: start,
									end: end,
									flags: flags
								});
							}
						}
					case 4:
						if (haveSnapshots)
							throw "Duplicate HLP source snapshot section";
						haveSnapshots = true;
						var seenHashes:Map<Int, Bool> = [];
						for (_ in 0...readUnsigned(input)) {
							var sourceHash = input.readInt32(),
								content = input.read(readUnsigned(input));
							if (sourceHash == 0 || seenHashes.exists(sourceHash) || hashBytes(content) != sourceHash)
								throw "Invalid HLP source snapshot";
							seenHashes.set(sourceHash, true);
							sourceSnapshots.push({sourceHash: sourceHash, content: content});
						}
					case 5:
						if (haveAdded)
							throw "Duplicate HLP added functions section";
						haveAdded = true;
						for (_ in 0...readUnsigned(input)) {
							var added:HlPatchAddedFunction = {
								stableId: readUnsigned(input),
								functionIndex: readUnsigned(input),
								type: readIndex(input),
								name: input.readString(readUnsigned(input))
							};
							for (other in addedFunctions)
								if (other.stableId == added.stableId || other.functionIndex == added.functionIndex)
									throw "Duplicate HLP added function";
							addedFunctions.push(added);
						}
					case 6:
						if (haveGlobals)
							throw "Duplicate HLP globals section";
						haveGlobals = true;
						globalPrefixHash = input.readInt32();
						baseGlobals = readUnsigned(input);
						for (_ in 0...readUnsigned(input)) {
							var kind = input.readByte();
							if (kind == 0)
								globals.push({type: readUnsigned(input), constant: false, fields: []});
							else if (kind == 1)
								globals.push({type: readUnsigned(input), constant: true, fields: [for (_ in 0...readUnsigned(input)) readUnsigned(input)]});
							else
								throw "Invalid HLP global kind";
						}
					default:
						input.position = end;
				}
				if (input.position != end)
					throw "Invalid HLP section length";
			}
			if (baseInts < 0 || functions.length == 0)
				throw "Missing required HLP section";
			for (global in globals)
				if (global.type >= baseTypes + types.length)
					throw "Invalid HLP global type";
			if (input.position != bytes.length)
				throw "Trailing HLP data";
			return {
				moduleId: moduleId,
				baseRevision: base,
				revision: revision,
				baseInts: baseInts,
				baseFloats: baseFloats,
				baseStrings: baseStrings,
				baseTypes: baseTypes,
				baseGlobals: baseGlobals,
				intPrefixHash: intPrefixHash,
				floatPrefixHash: floatPrefixHash,
				stringPrefixHash: stringPrefixHash,
				typePrefixHash: typePrefixHash,
				globalPrefixHash: globalPrefixHash,
				ints: ints,
				floats: floats,
				strings: strings,
				types: types,
				functions: functions,
				addedFunctions: addedFunctions,
				globals: globals,
				debugFiles: debugFiles,
				sourceSnapshots: sourceSnapshots
			};
		} catch (error:haxe.io.Eof) {
			throw "Truncated HLP data";
		}
	}

	static function hashBytes(bytes:Bytes):Int {
		var hash:Int = cast 0x811C9DC5;
		for (index in 0...bytes.length)
			hash = (hash ^ bytes.get(index)) * 16777619;
		return hash;
	}

	static function readType(input:BytesInput):HlTypeDef {
		var tag = input.readByte();
		if (tag == HlType.Enum)
			throw "Enum type patches require a structural reload";
		if (tag == HlType.Obj || tag == HlType.Struct) {
			var name = readIndex(input), base = readIndex(input), global = readUnsigned(input), fieldCount = readUnsigned(input),
				methodCount = readUnsigned(input), bindingCount = readUnsigned(input);
			var fields = [for (_ in 0...fieldCount) {name: readIndex(input), type: readIndex(input)}],
				methods = [
					for (_ in 0...methodCount)
						{name: readIndex(input), functionIndex: readIndex(input), prototype: readIndex(input)}
				],
				bindings = [for (_ in 0...bindingCount * 2) readIndex(input)];
			return tag == HlType.Obj ? Object(name, base, global, fields, methods, bindings) : Structure(name, global, fields, methods, bindings);
		}
		if (tag == HlType.Virtual)
			return Virtual([for (_ in 0...readUnsigned(input)) {name: readIndex(input), type: readIndex(input)}]);
		if (tag == HlType.Abstract)
			return Abstract(readIndex(input));
		if (tag == HlType.Ref || tag == HlType.Null || tag == HlType.Packed)
			return Parameterized(cast tag, readIndex(input));
		return if (tag == HlType.Fun) {
			var n = input.readByte();
			Function([for (_ in 0...n) readIndex(input)], readIndex(input));
		} else Simple(cast tag);
	}

	static function readFunction(input:BytesInput):HlPatchFunction {
		var stableId = readUnsigned(input),
			type = readIndex(input),
			index = readUnsigned(input),
			registerCount = readUnsigned(input),
			instructionCount = readUnsigned(input);
		var registers = [for (_ in 0...registerCount) readIndex(input)];
		var instructions = [];
		for (_ in 0...instructionCount) {
			var opcode = input.readByte();
			instructions.push({opcode: opcode, operands: readOperands(input, opcode)});
		}
		var relocations = [
			for (_ in 0...readUnsigned(input))
				{instruction: readUnsigned(input), stableId: readUnsigned(input)}
		];
		return {
			type: type,
			functionIndex: stableId,
			registers: registers,
			instructions: instructions,
			relocations: relocations,
			debug: []
		};
	}

	static function readOperands(input:BytesInput, op:Int):Array<Int>
		return switch HlOpcodeSchema.arity(op) {
			case HlOpcodeSchema.UNSUPPORTED: throw 'Unsupported patch opcode $op';
			case HlOpcodeSchema.VARIABLE_ARITY:
				var first = readIndex(input),
					second = readIndex(input),
					count = readOperandCount(input),
					operands = [first, second, count];
				for (_ in 0...count)
					operands.push(readIndex(input));
				operands;
			case count: [for (_ in 0...count) readIndex(input)];
		}

	static function readOperandCount(input:BytesInput):Int {
		var count = readUnsigned(input);
		// Match the native decoder's bound before reading any variable operands.
		if (count > 0x1000000)
			throw "Invalid variable operand count";
		return count;
	}

	static function readUnsigned(input:BytesInput):Int {
		var v = readIndex(input);
		if (v < 0)
			throw "Negative unsigned HLP index";
		return v;
	}

	static function readIndex(input:BytesInput):Int {
		var first = input.readByte();
		if ((first & 0x80) == 0)
			return first & 0x7F;
		if ((first & 0x40) == 0) {
			var v = input.readByte() | ((first & 31) << 8);
			return (first & 0x20) == 0 ? v : -v;
		}
		var v = ((first & 31) << 24) | (input.readByte() << 16) | (input.readByte() << 8) | input.readByte();
		return (first & 0x20) == 0 ? v : -v;
	}
}
