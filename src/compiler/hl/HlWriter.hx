package compiler.hl;

import haxe.io.Bytes as HaxeBytes;
import haxe.io.BytesOutput;
#if !haxeon
import haxe.io.Output;
#end
import haxe.ds.ObjectMap;
import sys.io.File;
import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.HlFunction.HlInstruction;
import compiler.hl.HlFunction.HlDebugLocation;

/** The source locations of one function's opcodes, by stable function identity; `locations[i]` belongs to opcode i. */
typedef HlOpcodeSourceSpanGroup = {
	final stableId:Int;
	final locations:Array<HlDebugLocation>;
}

/** Encoded opcode bytes paired with unresolved symbolic branch targets. */
private typedef EncodedInstruction = {
	final opcode:HlOpcode;
	final operands:Array<Int>;
}

/** Serializes the in-memory HashLink model using canonical HLB encodings. */
class HlWriter {
	public static inline final FUNCTION_IDENTITIES = 1;
	public static inline final OPCODE_SOURCE_SPANS = 2;
	public static inline final SOURCE_SNAPSHOTS = 3;

	#if haxeon
	final output:BytesOutput;
	#else
	final output:Output;
	#end
	#if haxeon
	final bytesOutput:Null<BytesOutput>;
	#else
	final bytesOutput:Null<ChunkedOutput>;
	#end
	final cache:Null<HlWriterCache>;
	var hasDebug:Bool = false;
	var debugFiles:Array<String> = [];
	var debugFileIndices:Map<String, Int> = [];

	#if haxeon
	public function new(?cache:HlWriterCache) {
		this.cache = cache;
		bytesOutput = new BytesOutput();
		bytesOutput.setBigEndian(false);
		output = bytesOutput;
	}
	#else
	public function new(?cache:HlWriterCache, ?destination:Output) {
		this.cache = cache;
		bytesOutput = destination == null ? new ChunkedOutput() : null;
		output = destination == null ? bytesOutput : destination;
		output.bigEndian = false;
	}
	#end

	/** Appends bytes that are never changed again (the cached prefix, cached function encodings, section payloads) without copying them. */
	function writeShared(bytes:HaxeBytes):Void {
		#if haxeon
		output.write(bytes);
		#else
		if (bytesOutput != null)
			bytesOutput.writeShared(bytes);
		else
			output.write(bytes);
		#end
	}

	function getBytes():HaxeBytes {
		if (bytesOutput == null)
			throw "HashLink writer has no byte buffer";
		return bytesOutput.getBytes();
	}

	public static function encode(code:HlCode, ?cache:HlWriterCache):HaxeBytes {
		HlValidator.validate(code, cache);
		var writer = new HlWriter(cache);
		writer.writeCode(code);
		return writer.getBytes();
	}

	#if !haxeon
	/** Write a module directly to an output without building a second module-sized buffer. */
	public static function writeTo(code:HlCode, destination:Output, ?cache:HlWriterCache):Void {
		HlValidator.validate(code, cache);
		new HlWriter(cache, destination).writeCode(code);
	}
	#end

	/** Validate before opening the destination, preserving an older file on validation failure. */
	public static function writeFile(code:HlCode, path:String, ?cache:HlWriterCache):Void {
		HlValidator.validate(code, cache);
		#if haxeon
		File.saveBytes(path, new HlWriter(cache).writeAndGetBytes(code));
		#else
		var destination = File.write(path, true);
		try {
			new HlWriter(cache, destination).writeCode(code);
		} catch (error:Dynamic) {
			destination.close();
			throw error;
		}
		destination.close();
		#end
	}

	#if haxeon
	function writeAndGetBytes(code:HlCode):HaxeBytes {
		writeCode(code);
		return getBytes();
	}
	#end

	/** Public because index encoding is part of the HLB format contract. */
	public static function encodeIndex(value:Int):HaxeBytes {
		var writer = new HlWriter();
		writer.writeIndex(value);
		return writer.getBytes();
	}

	/** Encodes one function using its canonical HLB function representation. */
	public static function encodeFunction(fn:HlFunction):HaxeBytes {
		var writer = new HlWriter();
		writer.writeFunction(fn);
		return writer.getBytes();
	}

	/** Measure exactly the components written by writeCode, without changing the module. */
	public static function reportSize(code:HlCode):Void {
		if (Sys.getEnv("HAXEON_IR_CENSUS") != "1")
			return;
		var writer = new HlWriter();
		writer.prepareDebugFiles(code);
		var part = new HlWriter();
		part.writeStrings(code.strings);
		var strings = part.getBytes().length;
		part = new HlWriter();
		if (writer.hasDebug) {
			part.writeUnsignedIndex(writer.debugFiles.length);
			part.writeStrings(writer.debugFiles);
		}
		var debugFiles = part.getBytes().length;
		var typeSizes:Array<{index:Int, bytes:Int}> = [], types = 0, reflection = 0;
		for (index in 0...code.types.length) {
			part = new HlWriter();
			part.writeType(code.types[index]);
			var size = part.getBytes().length;
			types += size;
			part = new HlWriter();
			part.writeReflectionMembers(code.types[index]);
			reflection += part.getBytes().length;
			typeSizes.push({index: index, bytes: size});
		}
		typeSizes.sort((a, b) -> a.bytes != b.bytes ? b.bytes - a.bytes : a.index - b.index);
		var stringSizes:Array<{index:Int, bytes:Int}> = [];
		for (index in 0...code.strings.length)
			stringSizes.push({index: index, bytes: HaxeBytes.ofString(code.strings[index]).length});
		stringSizes.sort((a, b) -> a.bytes != b.bytes ? b.bytes - a.bytes : a.index - b.index);
		var topTypes = [
			for (entry in typeSizes.slice(0, 30))
				'{"index":'
				+ entry.index
				+ ',"bytes":'
				+ entry.bytes
				+ ',"type":'
				+ haxe.Json.stringify(typeDescription(code.types[entry.index], code.strings))
				+ '}'];
		var topStrings = [
			for (entry in stringSizes.slice(0, 30))
				'{"index":'
				+ entry.index
				+ ',"bytes":'
				+ entry.bytes
				+ ',"value":'
				+ haxe.Json.stringify(code.strings[entry.index])
				+ '}'];
		var uses:Map<Int, Int> = [];
		for (fn in code.functions)
			for (opcode in fn.opcodes)
				switch opcode {
					case LoadString(_, index):
						uses.set(index, (uses.exists(index) ? uses.get(index) : 0) + 1);
					default:
				}
		var stringUses = [for (index => count in uses) {index: index, count: count}];
		stringUses.sort((a, b) -> a.count != b.count ? b.count - a.count : a.index - b.index);
		var topStringUses = [
			for (entry in stringUses.slice(0, 30))
				'{"index":'
				+ entry.index
				+ ',"references":'
				+ entry.count
				+ ',"value":'
				+ haxe.Json.stringify(code.strings[entry.index])
				+ '}'];
		part = new HlWriter();
		for (global in code.globals)
			part.writeIndex(global);
		var globals = part.getBytes().length;
		part = new HlWriter();
		for (native in code.natives) {
			part.writeIndex(native.library);
			part.writeIndex(native.name);
			part.writeIndex(native.type);
			part.writeUnsignedIndex(native.functionIndex);
		}
		var natives = part.getBytes().length;
		part = new HlWriter();
		part.writePrefixWithDebug(code, writer);
		var prefix = part.getBytes().length;
		var functions = 0, functionDebug = 0, debugSizes:Array<{index:Int, bytes:Int}> = [];
		for (fn in code.functions) {
			var plain = encodeFunction(fn).length;
			functions += plain;
			var debug = writer.encodePreparedFunction(fn).length - plain;
			functionDebug += debug;
			if (debug > 0)
				debugSizes.push({index: fn.functionIndex, bytes: debug});
		}
		debugSizes.sort((a, b) -> a.bytes != b.bytes ? b.bytes - a.bytes : a.index - b.index);
		var topFunctionDebug = [
			for (entry in debugSizes.slice(0, 30))
				'{"index":' + entry.index + ',"bytes":' + entry.bytes + '}'
		];
		part = new HlWriter();
		part.writeConstants(code);
		var constants = part.getBytes().length;
		part = new HlWriter();
		part.writeDebugSections(code);
		var debugSections = part.getBytes().length;
		var sections = [
			for (section in code.debugSections)
				'{"kind":'
				+ section.kind
				+ ',"version":'
				+ section.version
				+ ',"payload":'
				+ section.payload.length
				+ '}'];
		var scalarConstants = code.ints.length * 4 + code.floats.length * 8;
		var header = prefix - strings - debugFiles - types - globals - natives - scalarConstants;
		Sys.stderr()
			.writeString('SIZE_CENSUS {"target":"hl","header":' + header + ',"scalarConstants":' + scalarConstants + ',"strings":' + strings
				+ ',"debugFiles":' + debugFiles + ',"types":' + (types - reflection) + ',"reflectionMembers":' + reflection + ',"globals":' + globals
				+ ',"natives":' + natives + ',"functions":' + functions + ',"functionDebug":' + functionDebug + ',"constants":' + constants
				+ ',"debugSections":' + debugSections + ',"sections":[' + sections.join(",") + '],"topTypes":[' + topTypes.join(",") + '],"topStrings":['
				+ topStrings.join(",") + '],"topStringUses":[' + topStringUses.join(",") + '],"topFunctionDebug":[' + topFunctionDebug.join(",") + ']}\n');
	}

	function writePrefixWithDebug(code:HlCode, prepared:HlWriter):Void {
		hasDebug = prepared.hasDebug;
		debugFiles = prepared.debugFiles;
		debugFileIndices = prepared.debugFileIndices;
		writePrefix(code);
	}

	static function typeDescription(type:HlTypeDef, strings:Array<String>):String
		return switch type {
			case Object(name, _, _, _, _, _): "object " + strings[name];
			case Structure(name, _, _, _, _): "struct " + strings[name];
			case Enum(name, _, _): "enum " + strings[name];
			case Abstract(name): "abstract " + strings[name];
			default: Std.string(type);
		};

	/** Member records within the type table; their names and type headers remain in their own categories. */
	function writeReflectionMembers(type:HlTypeDef):Void
		switch type {
			case Object(_, _, _, fields, methods, bindings) | Structure(_, _, fields, methods, bindings):
				writeObjectMembers(fields, methods, bindings);
			case Virtual(name, fields):
				writeFields(fields);
			case Enum(_, _, constructors):
				writeEnumConstructors(constructors);
			default:
		}

	function writeCode(code:HlCode):Void {
		prepareDebugFiles(code);
		if (cache != null)
			cache.prepare(debugFiles);
		var prefix = cache == null ? null : cache.getPrefix(code);
		if (prefix == null) {
			var prefixWriter = new HlWriter();
			prefixWriter.hasDebug = hasDebug;
			prefixWriter.debugFiles = debugFiles;
			prefixWriter.debugFileIndices = debugFileIndices;
			prefixWriter.writePrefix(code);
			prefix = prefixWriter.getBytes();
			if (cache != null)
				cache.setPrefix(code, prefix);
		}
		writeShared(prefix);
		for (fn in code.functions) {
			var encoded = cache == null ? null : cache.get(fn);
			if (encoded == null) {
				encoded = encodePreparedFunction(fn);
				if (cache != null)
					cache.set(fn, encoded);
			}
			writeShared(encoded);
		}
		if (cache != null)
			cache.retainFunctions(code.functions);
		writeConstants(code);
		writeDebugSections(code);
	}

	/** Constants follow the functions in the HLB layout. */
	function writeConstants(code:HlCode):Void
		for (constant in code.constants) {
			writeUnsignedIndex(constant.global);
			writeUnsignedIndex(constant.fields.length);
			for (field in constant.fields)
				writeUnsignedIndex(field);
		}

	function writePrefix(code:HlCode):Void {
		output.writeString("HLB");
		output.writeByte(HlCode.VERSION);
		writeUnsignedIndex(hasDebug ? 1 : 0);
		writeUnsignedIndex(code.ints.length);
		writeUnsignedIndex(code.floats.length);
		writeUnsignedIndex(code.strings.length);
		writeUnsignedIndex(0); // byte blobs
		writeUnsignedIndex(code.types.length);
		writeUnsignedIndex(code.globals.length);
		writeUnsignedIndex(code.natives.length);
		writeUnsignedIndex(code.functions.length);
		writeUnsignedIndex(code.constants.length);
		writeUnsignedIndex(code.entryPoint);

		for (value in code.ints)
			output.writeInt32(value);
		for (value in code.floats)
			output.writeDouble(value);
		writeStrings(code.strings);
		output.writeInt32(0); // byte blob storage size
		if (hasDebug) {
			writeUnsignedIndex(debugFiles.length);
			writeStrings(debugFiles);
		}

		for (type in code.types)
			writeType(type);
		// HashLink's decoder reads the global type table before natives.
		for (global in code.globals)
			writeIndex(global);
		for (native in code.natives) {
			writeIndex(native.library);
			writeIndex(native.name);
			writeIndex(native.type);
			writeUnsignedIndex(native.functionIndex);
		}
	}

	function encodePreparedFunction(fn:HlFunction):HaxeBytes {
		var writer = new HlWriter();
		writer.hasDebug = hasDebug;
		writer.debugFiles = debugFiles;
		writer.debugFileIndices = debugFileIndices;
		writer.writeFunction(fn);
		return writer.getBytes();
	}

	function writeDebugSections(code:HlCode):Void {
		writeUnsignedIndex(code.debugSections.length);
		for (section in code.debugSections) {
			if (section.kind <= 0 || section.version <= 0 || section.flags < 0)
				throw "Invalid HLB debug section header";
			writeUnsignedIndex(section.kind);
			writeUnsignedIndex(section.version);
			writeUnsignedIndex(section.flags);
			var payload = section.payload;
			writeUnsignedIndex(payload.length);
			writeShared(payload);
		}
	}

	public static function encodeFunctionIdentities(identities:Array<compiler.hl.HlCode.HlFunctionIdentity>):HaxeBytes {
		var writer = new HlWriter();
		writer.writeUnsignedIndex(identities.length);
		for (identity in identities) {
			writer.writeUnsignedIndex(identity.stableId);
			writer.writeUnsignedIndex(identity.functionIndex);
			writer.writeSizedString(identity.qualifiedName);
			writer.writeSizedString(identity.displayName);
			writer.writeSizedString(identity.sourcePath);
			writer.writeIndex(identity.start + 1);
			writer.writeIndex(identity.end + 1);
			writer.writeUnsignedIndex(identity.line);
			writer.writeUnsignedIndex(identity.flags);
		}
		return writer.getBytes();
	}

	/** Encode the locations that lowering already keeps grouped by stable function identity: one mapping per opcode. */
	public static function encodeOpcodeSourceSpanGroups(groups:Array<HlOpcodeSourceSpanGroup>):HaxeBytes {
		var writer = new HlWriter(),
			files:Array<String> = [],
			fileIndices:Map<String, Int> = [],
			seenFunctions:Map<Int, Bool> = [];
		var previousPath = "";
		for (group in groups) {
			if (group.stableId < 0 || seenFunctions.exists(group.stableId))
				throw "Invalid HLB opcode source-span function";
			seenFunctions.set(group.stableId, true);
			for (location in group.locations) {
				var validRange = location.start == -1 && location.end == -1 || location.start >= 0 && location.end >= location.start;
				if (location.path == ""
					|| location.line < 1
					|| location.column < 1
					|| location.endLine < location.line
					|| location.endColumn < 1
					|| location.endLine == location.line
					&& location.endColumn < location.column
					|| location.flags < 0
					|| !validRange)
					throw "Invalid HLB opcode source span";
				if (location.path != previousPath) {
					previousPath = location.path;
					var fileIndex = fileIndices.get(previousPath);
					if (fileIndex == null) {
						fileIndex = files.length;
						fileIndices.set(previousPath, fileIndex);
						files.push(previousPath);
					}
				}
			}
		}
		writer.writeUnsignedIndex(files.length);
		for (file in files)
			writer.writeSizedString(file);
		var ordered = groups.copy();
		ordered.sort((left, right) -> left.stableId - right.stableId);
		writer.writeUnsignedIndex(ordered.length);
		previousPath = "";
		var previousFileIndex = -1;
		for (group in ordered) {
			writer.writeUnsignedIndex(group.stableId);
			writer.writeUnsignedIndex(group.locations.length);
			for (opcode in 0...group.locations.length) {
				var location = group.locations[opcode];
				writer.writeUnsignedIndex(opcode);
				if (location.path != previousPath) {
					previousPath = location.path;
					previousFileIndex = cast fileIndices.get(previousPath);
				}
				writer.writeUnsignedIndex(previousFileIndex);
				writer.writeIndex(location.start + 1);
				writer.writeIndex(location.end + 1);
				writer.writeUnsignedIndex(location.line);
				writer.writeUnsignedIndex(location.column);
				writer.writeUnsignedIndex(location.endLine);
				writer.writeUnsignedIndex(location.endColumn);
				writer.output.writeInt32(location.sourceHash);
				writer.writeUnsignedIndex(location.flags);
			}
		}
		return writer.getBytes();
	}

	public static function encodeSourceSnapshots(snapshots:Array<compiler.hl.HlCode.HlSourceSnapshot>):HaxeBytes {
		var writer = new HlWriter(),
			ordered = snapshots.copy(),
			seen:Map<Int, HaxeBytes> = [];
		ordered.sort((left, right) -> left.sourceHash < right.sourceHash ? -1 : left.sourceHash > right.sourceHash ? 1 : 0);
		writer.writeUnsignedIndex(ordered.length);
		for (snapshot in ordered) {
			if (snapshot.sourceHash == 0 || seen.exists(snapshot.sourceHash))
				throw "Invalid HLB source snapshot";
			seen.set(snapshot.sourceHash, snapshot.content);
			writer.output.writeInt32(snapshot.sourceHash);
			writer.writeUnsignedIndex(snapshot.content.length);
			writer.output.write(snapshot.content);
		}
		return writer.getBytes();
	}

	function writeSizedString(value:String):Void {
		var bytes = HaxeBytes.ofString(value);
		writeUnsignedIndex(bytes.length);
		output.write(bytes);
	}

	function writeStrings(strings:Array<String>):Void {
		var data = new BytesOutput();
		var lengths:Array<Int> = [];
		for (value in strings) {
			for (index in 0...value.length)
				if (value.charCodeAt(index) == 0)
					throw "HashLink String cannot contain NUL; use Bytes for binary data";
			var bytes = HaxeBytes.ofString(value);
			lengths.push(bytes.length);
			data.write(bytes);
			data.writeByte(0);
		}
		var bytes = data.getBytes();
		output.writeInt32(bytes.length);
		output.write(bytes);
		for (length in lengths)
			writeUnsignedIndex(length);
	}

	function writeType(type:HlTypeDef):Void {
		switch type {
			case Simple(kind):
				output.writeByte(kind);
			case Parameterized(kind, parameter):
				if (kind != HlType.Ref && kind != HlType.Null && kind != HlType.Packed)
					throw 'Unsupported parameterized HashLink type $kind';
				output.writeByte(kind);
				writeIndex(parameter);
			case Abstract(name):
				output.writeByte(HlType.Abstract);
				writeIndex(name);
			case Function(arguments, result):
				if (arguments.length > 255)
					throw "HL function types support at most 255 arguments";
				output.writeByte(HlType.Fun);
				output.writeByte(arguments.length);
				for (argument in arguments)
					writeIndex(argument);
				writeIndex(result);
			case Object(name, base, global, fields, methods, bindings):
				output.writeByte(HlType.Obj);
				writeObjectType(name, base, global, fields, methods, bindings);
			case Structure(name, global, fields, methods, bindings):
				output.writeByte(HlType.Struct);
				writeObjectType(name, -1, global, fields, methods, bindings);
			case Virtual(name, fields):
				output.writeByte(HlType.Virtual);
				writeIndex(name);
				writeUnsignedIndex(fields.length);
				writeFields(fields);
			case Enum(name, global, constructors):
				output.writeByte(HlType.Enum);
				writeIndex(name);
				writeUnsignedIndex(global);
				writeUnsignedIndex(constructors.length);
				writeEnumConstructors(constructors);
		}
	}

	function writeObjectType(name:Int, base:Int, global:Int, fields:Array<compiler.hl.HlCode.HlObjectField>, methods:Array<compiler.hl.HlCode.HlObjectMethod>,
			bindings:Array<Int>):Void {
		writeIndex(name);
		writeIndex(base);
		writeUnsignedIndex(global);
		writeUnsignedIndex(fields.length);
		writeUnsignedIndex(methods.length);
		writeUnsignedIndex(Std.int(bindings.length / 2));
		writeObjectMembers(fields, methods, bindings);
	}

	function writeFields(fields:Array<compiler.hl.HlCode.HlObjectField>):Void {
		for (field in fields) {
			writeIndex(field.name);
			writeIndex(field.type);
		}
	}

	function writeEnumConstructors(constructors:Array<compiler.hl.HlCode.HlEnumConstructor>):Void {
		for (constructor in constructors) {
			writeIndex(constructor.name);
			writeUnsignedIndex(constructor.params.length);
			for (param in constructor.params)
				writeIndex(param);
		}
	}

	function writeObjectMembers(fields:Array<compiler.hl.HlCode.HlObjectField>, methods:Array<compiler.hl.HlCode.HlObjectMethod>, bindings:Array<Int>):Void {
		writeFields(fields);
		for (method in methods) {
			writeIndex(method.name);
			writeUnsignedIndex(method.functionIndex);
			writeIndex(method.prototype);
		}
		for (binding in bindings)
			writeUnsignedIndex(binding);
	}

	function writeFunction(fn:HlFunction):Void {
		var instructions = lowerInstructions(fn);
		writeIndex(fn.type);
		writeUnsignedIndex(fn.functionIndex);
		writeUnsignedIndex(fn.registers.length);
		writeUnsignedIndex(instructions.length);
		for (type in fn.registers)
			writeIndex(type);
		for (instruction in instructions)
			writeOpcode(instruction.opcode, instruction.operands);
		if (hasDebug) {
			writeDebugLocations(fn);
			writeUnsignedIndex(fn.debugAssignments.length);
			for (assignment in fn.debugAssignments) {
				writeUnsignedIndex(assignment.name);
				writeIndex(assignment.position + 1);
				writeIndex(assignment.scopeEnd + 1);
			}
		}
	}

	function prepareDebugFiles(code:HlCode):Void {
		hasDebug = false;
		for (fn in code.functions)
			if (fn.debugLocations.length > 0)
				hasDebug = true;
		if (!hasDebug) {
			if (cache != null)
				cache.retainPaths(new ObjectMap());
			return;
		}
		var activePaths:ObjectMap<HlFunction, Array<String>> = cache == null ? null : new ObjectMap();
		for (fn in code.functions) {
			if (fn.debugLocations.length == 0) {
				internDebugFile("<generated>");
				continue;
			}
			if (cache == null) {
				for (location in fn.debugLocations)
					internDebugFile(location.path);
				continue;
			}
			var paths = cache.paths(fn);
			if (paths == null) {
				paths = [];
				var previousPath = "";
				for (location in fn.debugLocations)
					if (location.path != previousPath) {
						previousPath = location.path;
						if (paths.indexOf(previousPath) < 0)
							paths.push(previousPath);
					}
			}
			activePaths.set(fn, paths);
			for (path in paths)
				internDebugFile(path);
		}
		if (cache != null)
			cache.retainPaths(activePaths);
	}

	function internDebugFile(path:String):Int {
		if (debugFileIndices.exists(path))
			return debugFileIndices.get(path);
		var index = debugFiles.length;
		if (index > 0x7FFF)
			throw "Too many HashLink debug files";
		debugFiles.push(path);
		debugFileIndices.set(path, index);
		return index;
	}

	/** The location of a function that was given none. */
	static final generatedLocation = new HlDebugLocation("<generated>", 1, 1, 1, 1, 0, -1, -1, 1);

	function writeDebugLocations(fn:HlFunction):Void {
		var currentFile = -1, currentLine = 0, index = 0;
		while (index < fn.opcodes.length) {
			var location:HlDebugLocation = fn.debugLocations.length == 0 ? generatedLocation : fn.debugLocations[index];
			if (location.line > 0x1FFFFF)
				throw 'Debug line ${location.line} exceeds the HashLink format limit';
			if (!debugFileIndices.exists(location.path))
				throw 'Missing HashLink debug file index for "${location.path}"';
			var file = debugFileIndices.get(location.path);
			if (file != currentFile) {
				output.writeByte(((file >> 8) << 1) | 1);
				output.writeByte(file & 0xFF);
				currentFile = file;
			}
			if (location.line == currentLine) {
				var count = 1;
				while (count < 15 && index + count < fn.opcodes.length) {
					if (fn.debugLocations.length != 0) {
						var next = fn.debugLocations[index + count];
						if (next.path != location.path || next.line != currentLine)
							break;
					}
					count++;
				}
				output.writeByte((count << 2) | 2);
				index += count;
			} else {
				var delta = location.line - currentLine;
				if (delta > 0 && delta <= 31)
					output.writeByte((delta << 3) | 4);
				else {
					output.writeByte((location.line & 0x1F) << 3);
					output.writeByte((location.line >> 5) & 0xFF);
					output.writeByte((location.line >> 13) & 0xFF);
				}
				currentLine = location.line;
				index++;
			}
		}
	}

	function lowerInstructions(fn:HlFunction):Array<EncodedInstruction> {
		var labels = HlValidator.collectLabels(fn);
		var result:Array<EncodedInstruction> = [];
		for (instruction in fn.opcodes) {
			var encoded:EncodedInstruction = switch instruction {
				case Move(destination, source): {opcode: HlOpcode.Mov, operands: [destination, source]};
				case LoadInt(destination, constant):
					{opcode: HlOpcode.Int, operands: [destination, constant]};
				case LoadFloat(destination, constant):
					{opcode: HlOpcode.Float, operands: [destination, constant]};
				case LoadString(destination, constant):
					{opcode: HlOpcode.String, operands: [destination, constant]};
				case LoadBool(destination, value):
					{opcode: HlOpcode.Bool, operands: [destination, value ? 1 : 0]};
				case LoadNull(destination):
					{opcode: HlOpcode.Null, operands: [destination]};
				case LoadType(destination, type):
					{opcode: HlOpcode.Type, operands: [destination, type]};
				case ToDyn(destination, source):
					{opcode: HlOpcode.ToDyn, operands: [destination, source]};
				case ToSFloat(destination, source):
					{opcode: HlOpcode.ToSFloat, operands: [destination, source]};
				case ToInt(destination, source):
					{opcode: HlOpcode.ToInt, operands: [destination, source]};
				case UnsafeCast(destination, source):
					{opcode: HlOpcode.UnsafeCast, operands: [destination, source]};
				case Ref(destination, source):
					{opcode: HlOpcode.Ref, operands: [destination, source]};
				case Unref(destination, source):
					{opcode: HlOpcode.Unref, operands: [destination, source]};
				case Setref(destination, source):
					{opcode: HlOpcode.Setref, operands: [destination, source]};
				case RefOffset(destination, source, index):
					{opcode: HlOpcode.RefOffset, operands: [destination, source, index]};
				case SafeCast(destination, source):
					{opcode: HlOpcode.SafeCast, operands: [destination, source]};
				case GlobalGet(destination, global):
					{opcode: HlOpcode.GetGlobal, operands: [destination, global]};
				case GlobalSet(global, source):
					{opcode: HlOpcode.SetGlobal, operands: [global, source]};
				case Add(destination, left, right):
					{opcode: HlOpcode.Add, operands: [destination, left, right]};
				case Sub(destination, left, right):
					{opcode: HlOpcode.Sub, operands: [destination, left, right]};
				case Mul(destination, left, right): {opcode: HlOpcode.Mul, operands: [destination, left, right]};
				case Div(destination, left, right): {opcode: HlOpcode.SDiv, operands: [destination, left, right]};
				case Mod(destination, left, right): {opcode: HlOpcode.SMod, operands: [destination, left, right]};
				case BitAnd(destination, left, right): {opcode: HlOpcode.And, operands: [destination, left, right]};
				case BitXor(destination, left, right): {opcode: HlOpcode.Xor, operands: [destination, left, right]};
				case BitOr(destination, left, right): {opcode: HlOpcode.Or, operands: [destination, left, right]};
				case ShiftLeft(destination, left, right): {opcode: HlOpcode.Shl, operands: [destination, left, right]};
				case ShiftRight(destination, left, right): {opcode: HlOpcode.SShr, operands: [destination, left, right]};
				case UnsignedShiftRight(destination, left, right): {opcode: HlOpcode.UShr, operands: [destination, left, right]};
				case Call0(destination, functionIndex):
					{opcode: HlOpcode.Call0, operands: [destination, functionIndex]};
				case Call1(destination, functionIndex, argument):
					{opcode: HlOpcode.Call1, operands: [destination, functionIndex, argument]};
				case Call2(destination, functionIndex, argument1, argument2):
					{opcode: HlOpcode.Call2, operands: [destination, functionIndex, argument1, argument2]};
				case CallN(destination, functionIndex, arguments):
					{opcode: HlOpcode.CallN, operands: [destination, functionIndex, arguments.length].concat(arguments)};
				case StaticClosure(destination, functionIndex):
					{opcode: HlOpcode.StaticClosure, operands: [destination, functionIndex]};
				case InstanceClosure(destination, functionIndex, receiver):
					{opcode: HlOpcode.InstanceClosure, operands: [destination, functionIndex, receiver]};
				case NullCheck(register):
					{opcode: HlOpcode.NullCheck, operands: [register]};
				case CallClosure(destination, closure, arguments):
					{opcode: HlOpcode.CallClosure, operands: [destination, closure, arguments.length].concat(arguments)};
				case ToVirtual(destination, source):
					{opcode: HlOpcode.ToVirtual, operands: [destination, source]};
				case CallMethod(destination, method, arguments):
					{opcode: HlOpcode.CallMethod, operands: [destination, method, arguments.length].concat(arguments)};
				case New(destination, _, _):
					// ONew has no encoded type operand. HashLink derives the
					// allocation type from the destination register's type.
					{opcode: HlOpcode.New, operands: [destination]};
				case FieldGet(destination, object, field):
					{opcode: HlOpcode.Field, operands: [destination, object, field]};
				case FieldSet(object, field, source):
					{opcode: HlOpcode.SetField, operands: [object, field, source]};
				case ArrayGet(destination, array, index):
					{opcode: HlOpcode.GetArray, operands: [destination, array, index]};
				case ArraySet(array, index, source):
					{opcode: HlOpcode.SetArray, operands: [array, index, source]};
				case GetI8(destination, pointer, offset):
					{opcode: HlOpcode.GetI8, operands: [destination, pointer, offset]};
				case GetI16(destination, pointer, offset):
					{opcode: HlOpcode.GetI16, operands: [destination, pointer, offset]};
				case GetMem(destination, pointer, offset):
					{opcode: HlOpcode.GetMem, operands: [destination, pointer, offset]};
				case SetI8(pointer, offset, source):
					{opcode: HlOpcode.SetI8, operands: [pointer, offset, source]};
				case SetI16(pointer, offset, source):
					{opcode: HlOpcode.SetI16, operands: [pointer, offset, source]};
				case SetMem(pointer, offset, source):
					{opcode: HlOpcode.SetMem, operands: [pointer, offset, source]};
				case ArraySize(destination, array):
					{opcode: HlOpcode.ArraySize, operands: [destination, array]};
				case RefData(destination, array):
					{opcode: HlOpcode.RefData, operands: [destination, array]};
				case MakeEnum(destination, constructor, arguments):
					{opcode: HlOpcode.MakeEnum, operands: [destination, constructor, arguments.length].concat(arguments)};
				case EnumIndex(destination, value):
					{opcode: HlOpcode.EnumIndex, operands: [destination, value]};
				case EnumField(destination, value, constructor, field):
					{opcode: HlOpcode.EnumField, operands: [destination, value, constructor, field]};
				case JumpSignedLessOrEqual(left, right, target):
					var targetPosition = requireLabel(labels, target);
					{opcode: HlOpcode.JSLte, operands: [left, right, targetPosition - (result.length + 1)]};
				case JumpSignedLess(left, right, target):
					var targetPosition = requireLabel(labels, target);
					{opcode: HlOpcode.JSLt, operands: [left, right, targetPosition - (result.length + 1)]};
				case JumpUnsignedLess(left, right, target):
					var targetPosition = requireLabel(labels, target);
					{opcode: HlOpcode.JULt, operands: [left, right, targetPosition - (result.length + 1)]};
				case JumpNull(value, target):
					var targetPosition = requireLabel(labels, target);
					{opcode: HlOpcode.JNull, operands: [value, targetPosition - (result.length + 1)]};
				case JumpEqual(left, right, target):
					var targetPosition = requireLabel(labels, target);
					{opcode: HlOpcode.JEq, operands: [left, right, targetPosition - (result.length + 1)]};
				case JumpTrue(condition, target):
					var targetPosition = requireLabel(labels, target);
					{opcode: HlOpcode.JTrue, operands: [condition, targetPosition - (result.length + 1)]};
				case Jump(target):
					var targetPosition = requireLabel(labels, target);
					{opcode: HlOpcode.JAlways, operands: [targetPosition - (result.length + 1)]};
				case Trap(destination, target, preserveExceptionStack):
					var targetPosition = requireLabel(labels, target);
					{
						opcode: preserveExceptionStack == true ? HlOpcode.CleanupTrap : HlOpcode.Trap,
						operands: [destination, targetPosition - (result.length + 1)]
					};
				case EndTrap(destination, preserveExceptionStack):
					{opcode: preserveExceptionStack == true ? HlOpcode.EndCleanupTrap : HlOpcode.EndTrap, operands: [destination]};
				case Label(_): {opcode: HlOpcode.Label, operands: []};
				case Return(register):
					{opcode: HlOpcode.Ret, operands: [register]};
				case Throw(register):
					{opcode: HlOpcode.Throw, operands: [register]};
				case Rethrow(register):
					{opcode: HlOpcode.Rethrow, operands: [register]};
			}
			HlOpcodeSchema.validate(encoded.opcode, encoded.operands);
			result.push(encoded);
		}
		return result;
	}

	static function requireLabel(labels:Map<String, Int>, target:String):Int {
		if (!labels.exists(target))
			throw 'Unknown HashLink jump label "$target"';
		return labels.get(target);
	}

	function writeOpcode(opcode:HlOpcode, operands:Array<Int>):Void {
		output.writeByte(opcode);
		for (operand in operands)
			writeIndex(operand);
	}

	function writeUnsignedIndex(value:Int):Void {
		if (value < 0)
			throw 'Expected unsigned index, got $value';
		writeIndex(value);
	}

	/** Inverse of HashLink's signed variable-width hl_read_index. */
	function writeIndex(value:Int):Void {
		var negative = value < 0;
		var magnitude = negative ? -value : value;
		if (magnitude < 0x80 && !negative) {
			output.writeByte(magnitude);
		} else if (magnitude < 0x2000) {
			output.writeByte(0x80 | (negative ? 0x20 : 0) | (magnitude >> 8));
			output.writeByte(magnitude & 0xFF);
		} else if (magnitude < 0x20000000) {
			output.writeByte(0xC0 | (negative ? 0x20 : 0) | (magnitude >> 24));
			output.writeByte((magnitude >> 16) & 0xFF);
			output.writeByte((magnitude >> 8) & 0xFF);
			output.writeByte(magnitude & 0xFF);
		} else {
			throw 'HL index is out of range: $value';
		}
	}
}
