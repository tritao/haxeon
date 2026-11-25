package compiler.hl;

import compiler.core.InternalError;
import compiler.hl.HlCode.HlFunctionIdentity;
import compiler.hl.HlCode.HlTypeDef;
import haxe.io.Bytes;
import haxe.io.BytesInput;

/**
 * Decodes a HashLink module (HLB), in the order and with the version rules of the VM's loader (`hl_code_read` in
 * vendor/hashlink/src/code.c), from version 4 (stock Haxe) to the version this compiler writes. Opcodes take their operand
 * counts from HlOpcodeSchema.decodeArity, so a module any compiler wrote reads; the encodings themselves are
 * HlBytecodeInput's, shared with the patch reader. Used by `haxeon dev hl-stat` and to check HlWriter against an independent
 * decoder (HlModuleRoundTripMain).
 */
class HlModuleReader {
	public static function read(bytes:Bytes):HlModule {
		var input = new BytesInput(bytes);
		input.bigEndian = false;
		if (bytes.length < 4 || input.readString(3) != "HLB")
			throw new InternalError("Not a HashLink module");
		var version = input.readByte();
		if (version < 4 || version > HlCode.VERSION)
			throw new InternalError('Unsupported HLB version $version');
		var sizes:Array<HlModulePart> = [], mark = input.position;
		function part(name:String):Void {
			sizes.push({name: name, bytes: input.position - mark});
			mark = input.position;
		}
		var flags = unsigned(input),
			intCount = unsigned(input),
			floatCount = unsigned(input),
			stringCount = unsigned(input),
			byteCount = version >= 5 ? unsigned(input) : 0,
			typeCount = unsigned(input),
			globalCount = unsigned(input),
			nativeCount = unsigned(input),
			functionCount = unsigned(input),
			constantCount = unsigned(input),
			entryPoint = unsigned(input),
			debug = flags & 1 != 0;
		part("header");
		var ints = [for (_ in 0...intCount) input.readInt32()], floats = [for (_ in 0...floatCount) input.readDouble()];
		part("constants (ints and floats)");
		var strings = HlBytecodeInput.strings(input, stringCount, "HLB");
		part("strings");
		var byteData = Bytes.alloc(0), bytePositions:Array<Int> = [];
		if (version >= 5) {
			byteData = input.read(input.readInt32());
			bytePositions = [for (_ in 0...byteCount) unsigned(input)];
		}
		part("bytes");
		var debugFiles = debug ? HlBytecodeInput.strings(input, unsigned(input), "HLB") : [];
		part("debug files");
		var types = [for (_ in 0...typeCount) HlBytecodeInput.type(input, version >= 8, "HLB")];
		part("types");
		var globals = [for (_ in 0...globalCount) HlBytecodeInput.index(input)];
		var natives = [for (_ in 0...nativeCount)
			{
				library: HlBytecodeInput.index(input),
				name: HlBytecodeInput.index(input),
				type: HlBytecodeInput.index(input),
				functionIndex: unsigned(input)
			}];
		part("globals and natives");
		var functions:Array<HlModuleFunction> = [], instructionBytes = 0, debugBytes = 0;
		for (_ in 0...functionCount) {
			var start = input.position;
			var type = HlBytecodeInput.index(input),
				functionIndex = unsigned(input),
				registerCount = unsigned(input),
				instructionCount = unsigned(input);
			var registers = [for (_ in 0...registerCount) HlBytecodeInput.index(input)],
				instructions:Array<HlModuleInstruction> = [];
			for (_ in 0...instructionCount) {
				var opcode = input.readByte();
				instructions.push({
					opcode: opcode,
					operands: HlBytecodeInput.operands(input, opcode, HlOpcodeSchema.decodeArity(opcode), "HLB")
				});
			}
			instructionBytes += input.position - start;
			var debugStart = input.position, lines:Array<HlModuleLine> = [], assignments:Array<HlModuleAssignment> = [];
			if (debug) {
				lines = readLines(input, instructionCount, debugFiles.length);
				for (_ in 0...(version >= 3 ? unsigned(input) : 0))
					assignments.push({
						name: unsigned(input),
						position: HlBytecodeInput.index(input) - 1,
						scopeEnd: version >= 6 ? HlBytecodeInput.index(input) - 1 : -1
					});
			}
			debugBytes += input.position - debugStart;
			functions.push({
				type: type,
				functionIndex: functionIndex,
				registers: registers,
				instructions: instructions,
				lines: lines,
				assignments: assignments,
				bytes: input.position - start
			});
		}
		sizes.push({name: "function instructions", bytes: instructionBytes});
		sizes.push({name: "function debug lines and assignments", bytes: debugBytes});
		mark = input.position;
		var constants = [for (_ in 0...constantCount)
			{
				global: unsigned(input), fields: [for (_ in 0...unsigned(input)) unsigned(input)]
			}];
		part("constant objects");
		var sections:Array<HlModuleSection> = [];
		if (version >= 7)
			for (_ in 0...unsigned(input)) {
				var kind = unsigned(input),
					sectionVersion = unsigned(input),
					sectionFlags = unsigned(input),
					size = unsigned(input),
					payload = input.read(size);
				sections.push({
					kind: kind,
					version: sectionVersion,
					flags: sectionFlags,
					stored: size,
					payload: sectionFlags & HlWriter.COMPRESSED != 0 ? decompress(payload) : payload
				});
			}
		part("debug sections");
		if (input.position != bytes.length)
			throw new InternalError('HLB module has ${bytes.length - input.position} bytes after its last section');
		return {
			version: version,
			debug: debug,
			ints: ints,
			floats: floats,
			strings: strings,
			byteData: byteData,
			bytePositions: bytePositions,
			debugFiles: debugFiles,
			types: types,
			globals: globals,
			natives: natives,
			functions: functions,
			constants: constants,
			entryPoint: entryPoint,
			sections: sections,
			sizes: sizes
		};
	}

	/** A COMPRESSED section's payload: its decoded size, then the LZ4 block. */
	static function decompress(payload:Bytes):Bytes {
		var input = new BytesInput(payload), size = unsigned(input);
		return HlLz4.decompress(payload, input.position, payload.length - input.position, size);
	}

	/** The function identities of a FUNCTION_IDENTITIES section, as HlWriter.encodeFunctionIdentities writes them. */
	public static function functionIdentities(payload:Bytes):Array<HlFunctionIdentity> {
		var input = new BytesInput(payload);
		function text():String
			return input.readString(unsigned(input));
		return [for (_ in 0...unsigned(input))
			{
				stableId: unsigned(input),
				functionIndex: unsigned(input),
				qualifiedName: text(),
				displayName: text(),
				sourcePath: text(),
				start: HlBytecodeInput.index(input) - 1,
				end: HlBytecodeInput.index(input) - 1,
				line: unsigned(input),
				flags: unsigned(input)
			}];
	}

	/**
	 * The file and line of each instruction, as `hl_read_debug_infos` decodes them: a file change (bit 0), a run of
	 * instructions on one line then a line delta (bit 1), one instruction after a small delta (bit 2), or an absolute line.
	 */
	static function readLines(input:BytesInput, count:Int, files:Int):Array<HlModuleLine> {
		var result:Array<HlModuleLine> = [], file = -1, line = 0;
		while (result.length < count) {
			var c = input.readByte();
			if (c & 1 != 0) {
				file = ((c >> 1) << 8) | input.readByte();
				if (file >= files)
					throw new InternalError("Invalid HLB debug file");
			} else if (c & 2 != 0) {
				var delta = c >> 6, run = (c >> 2) & 15;
				if (result.length + run > count)
					throw new InternalError("HLB debug lines outside the function");
				for (_ in 0...run)
					result.push({file: file, line: line});
				line += delta;
			} else if (c & 4 != 0) {
				line += c >> 3;
				result.push({file: file, line: line});
			} else {
				var second = input.readByte(), third = input.readByte();
				line = (c >> 3) | (second << 5) | (third << 13);
				result.push({file: file, line: line});
			}
		}
		return result;
	}

	static inline function unsigned(input:BytesInput):Int
		return HlBytecodeInput.unsigned(input, "HLB");
}

/** A decoded module: its tables as the file holds them, its functions, its debug sections, and the bytes of each part. */
typedef HlModule = {
	final version:Int;
	final debug:Bool;
	final ints:Array<Int>;
	final floats:Array<Float>;
	final strings:Array<String>;
	final byteData:Bytes;
	final bytePositions:Array<Int>;
	final debugFiles:Array<String>;
	final types:Array<HlTypeDef>;
	final globals:Array<Int>;
	final natives:Array<HlModuleNative>;
	final functions:Array<HlModuleFunction>;
	final constants:Array<HlModuleConstant>;
	final entryPoint:Int;
	final sections:Array<HlModuleSection>;
	final sizes:Array<HlModulePart>;
}

typedef HlModuleNative = {
	final library:Int;
	final name:Int;
	final type:Int;
	final functionIndex:Int;
}

typedef HlModuleFunction = {
	final type:Int;
	final functionIndex:Int;
	final registers:Array<Int>;
	final instructions:Array<HlModuleInstruction>;

	/** One per instruction when the module has debug information, else empty. */
	final lines:Array<HlModuleLine>;

	final assignments:Array<HlModuleAssignment>;

	/** The function's bytes in the module, debug information included. */
	final bytes:Int;
}

typedef HlModuleInstruction = {
	final opcode:Int;
	final operands:Array<Int>;
}

typedef HlModuleLine = {
	final file:Int;
	final line:Int;
}

typedef HlModuleAssignment = {
	final name:Int;
	final position:Int;
	final scopeEnd:Int;
}

typedef HlModuleConstant = {
	final global:Int;
	final fields:Array<Int>;
}

typedef HlModuleSection = {
	final kind:Int;
	final version:Int;
	final flags:Int;

	/** The payload's size in the module, compressed or not. */
	final stored:Int;

	/** The payload, decompressed. */
	final payload:Bytes;
}

typedef HlModulePart = {
	final name:String;
	final bytes:Int;
}
