package compiler.hl;

import haxe.io.Bytes as HaxeBytes;
import haxeon.io.ByteSink;
import haxeon.io.SegmentedBytes;
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

/** Serializes the in-memory HashLink model using canonical HLB encodings. */
class HlWriter {
	public static inline final FUNCTION_IDENTITIES = 1;
	public static inline final OPCODE_SOURCE_SPANS = 2;
	public static inline final SOURCE_SNAPSHOTS = 3;

	final output:ByteSink = new ByteSink();
	final cache:Null<HlWriterCache>;
	var hasDebug:Bool = false;
	var debugFiles:Array<String> = [];
	var debugFileIndices:Map<String, Int> = [];

	public function new(?cache:HlWriterCache) {
		this.cache = cache;
	}

	/** Appends bytes that are never changed again (the cached prefix, cached function encodings, section payloads) without copying them. */
	function writeShared(bytes:HaxeBytes):Void
		output.appendShared(bytes);

	/** What this writer wrote, as one buffer: for the small results (an index, a function, a section header). */
	function bytes():HaxeBytes
		return output.finish().flatten();

	/** The module as segments: the cached encodings of unchanged functions are shared, not copied. */
	public static function encode(code:HlCode, ?cache:HlWriterCache):SegmentedBytes {
		HlValidator.validate(code, cache);
		var writer = new HlWriter(cache);
		writer.writeCode(code);
		return writer.output.finish();
	}

	#if !haxeon
	/** Write a module to an output. */
	public static function writeTo(code:HlCode, destination:haxe.io.Output, ?cache:HlWriterCache):Void
		encode(code, cache).writeTo(destination);
	#end

	/** Validate before opening the destination, preserving an older file on validation failure. */
	public static function writeFile(code:HlCode, path:String, ?cache:HlWriterCache):Void
		saveSegments(encode(code, cache), path);

	/** Writes a module to `path` through a temporary file beside it, so a reader never sees half a module. */
	public static function saveSegments(module:SegmentedBytes, path:String):Void {
		// The self-hosted build's standard library has no streaming file output yet.
		#if haxeon
		File.saveBytes(path, module.flatten());
		#else
		var temporary = path + ".tmp",
			destination = File.write(temporary, true);
		try {
			module.writeTo(destination);
		} catch (error:Dynamic) {
			destination.close();
			sys.FileSystem.deleteFile(temporary);
			throw error;
		}
		destination.close();
		if (sys.FileSystem.exists(path))
			sys.FileSystem.deleteFile(path);
		sys.FileSystem.rename(temporary, path);
		#end
	}

	/** Public because index encoding is part of the HLB format contract. */
	public static function encodeIndex(value:Int):HaxeBytes {
		var writer = new HlWriter();
		writer.writeIndex(value);
		return writer.bytes();
	}

	/** Encodes one function using its canonical HLB function representation. */
	public static function encodeFunction(fn:HlFunction):HaxeBytes {
		var writer = new HlWriter();
		writer.writeFunction(fn);
		return writer.bytes();
	}

	/** Measure exactly the components written by writeCode, without changing the module. */
	public static function reportSize(code:HlCode):Void {
		if (Sys.getEnv("HAXEON_IR_CENSUS") != "1")
			return;
		var writer = new HlWriter();
		writer.prepareDebugFiles(code);
		var part = new HlWriter();
		part.writeStrings(code.strings);
		var strings = part.output.length;
		part = new HlWriter();
		if (writer.hasDebug) {
			part.writeUnsignedIndex(writer.debugFiles.length);
			part.writeStrings(writer.debugFiles);
		}
		var debugFiles = part.output.length;
		var typeSizes:Array<{index:Int, bytes:Int}> = [], types = 0, reflection = 0;
		for (index in 0...code.types.length) {
			part = new HlWriter();
			part.writeType(code.types[index]);
			var size = part.output.length;
			types += size;
			part = new HlWriter();
			part.writeReflectionMembers(code.types[index]);
			reflection += part.output.length;
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
		var globals = part.output.length;
		part = new HlWriter();
		for (native in code.natives) {
			part.writeIndex(native.library);
			part.writeIndex(native.name);
			part.writeIndex(native.type);
			part.writeUnsignedIndex(native.functionIndex);
		}
		var natives = part.output.length;
		part = new HlWriter();
		part.writePrefixWithDebug(code, writer);
		var prefix = part.output.length;
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
		var constants = part.output.length;
		part = new HlWriter();
		part.writeDebugSections(code);
		var debugSections = part.output.length;
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
			prefix = prefixWriter.bytes();
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
		return writer.bytes();
	}

	function writeDebugSections(code:HlCode):Void {
		writeUnsignedIndex(code.debugSections.length);
		for (section in code.debugSections) {
			if (section.kind <= 0 || section.version <= 0 || section.flags < 0)
				throw "Invalid HLB debug section header";
			writeUnsignedIndex(section.kind);
			writeUnsignedIndex(section.version);
			writeUnsignedIndex(section.flags);
			var payload = section.payloadFor(cache);
			writeUnsignedIndex(payload.length);
			output.appendSegments(payload);
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
		return writer.bytes();
	}

	/** Encode the locations that lowering already keeps grouped by stable function identity: one mapping per opcode. */
	/**
	 * With a cache, a group whose `locations` array is the very one encoded last time (an unchanged function) reuses those bytes as long
	 * as every file it names has the same index; only the changed functions are encoded.
	 */
	public static function encodeOpcodeSourceSpanGroups(groups:Array<HlOpcodeSourceSpanGroup>, ?cache:HlWriterCache):SegmentedBytes {
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
		var used:Null<Array<Array<HlDebugLocation>>> = cache == null ? null : [];
		for (group in ordered) {
			var cached = cache == null ? null : cache.spanGroup(group.locations, group.stableId, fileIndices);
			if (cached == null) {
				var groupWriter = new HlWriter();
				groupWriter.writeSpanGroup(group, fileIndices);
				cached = groupWriter.bytes();
				if (cache != null)
					cache.setSpanGroup(group.locations, group.stableId, cached, fileIndices);
			}
			if (used != null)
				used.push(group.locations);
			writer.writeShared(cached);
		}
		if (cache != null)
			cache.retainSpanGroups(used);
		return writer.output.finish();
	}

	function writeSpanGroup(group:HlOpcodeSourceSpanGroup, fileIndices:Map<String, Int>):Void {
		writeUnsignedIndex(group.stableId);
		writeUnsignedIndex(group.locations.length);
		var previousPath = "", previousFileIndex = -1;
		for (opcode in 0...group.locations.length) {
			var location = group.locations[opcode];
			writeUnsignedIndex(opcode);
			if (location.path != previousPath) {
				previousPath = location.path;
				previousFileIndex = cast fileIndices.get(previousPath);
			}
			writeUnsignedIndex(previousFileIndex);
			writeIndex(location.start + 1);
			writeIndex(location.end + 1);
			writeUnsignedIndex(location.line);
			writeUnsignedIndex(location.column);
			writeUnsignedIndex(location.endLine);
			writeUnsignedIndex(location.endColumn);
			output.writeInt32(location.sourceHash);
			writeUnsignedIndex(location.flags);
		}
	}

	public static function encodeSourceSnapshots(snapshots:Array<compiler.hl.HlCode.HlSourceSnapshot>):SegmentedBytes {
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
			// Source contents are never changed after they are read, so the section takes them without copying them.
			writer.writeShared(snapshot.content);
		}
		return writer.output.finish();
	}

	function writeSizedString(value:String):Void {
		var bytes = HaxeBytes.ofString(value);
		writeUnsignedIndex(bytes.length);
		output.write(bytes);
	}

	function writeStrings(strings:Array<String>):Void {
		var encoded:Array<HaxeBytes> = [], lengths:Array<Int> = [], total = 0;
		for (value in strings) {
			for (index in 0...value.length)
				if (value.charCodeAt(index) == 0)
					throw "HashLink String cannot contain NUL; use Bytes for binary data";
			var bytes = HaxeBytes.ofString(value);
			encoded.push(bytes);
			lengths.push(bytes.length);
			total += bytes.length + 1;
		}
		output.writeInt32(total);
		for (bytes in encoded) {
			output.write(bytes);
			output.writeByte(0);
		}
		for (length in lengths)
			writeUnsignedIndex(length);
	}

	function writeType(type:HlTypeDef):Void {
		switch type {
			case EnumTag(boxedType, cacheGlobals):
				output.writeByte(HlType.EnumTag);
				writeIndex(boxedType);
				writeUnsignedIndex(cacheGlobals.length);
				for (global in cacheGlobals)
					writeUnsignedIndex(global);
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
		var labels = HlValidator.collectLabels(fn);
		writeIndex(fn.type);
		writeUnsignedIndex(fn.functionIndex);
		writeUnsignedIndex(fn.registers.length);
		// Every instruction, labels included, is one HashLink instruction.
		writeUnsignedIndex(fn.opcodes.length);
		for (type in fn.registers)
			writeIndex(type);
		for (position in 0...fn.opcodes.length) {
			var opcode = lowerInstruction(fn.opcodes[position], position, labels);
			HlOpcodeSchema.validate(opcode, operands);
			writeOpcode(opcode, operands);
		}
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

	/** The operands of the instruction being lowered; reused by every instruction of the writer. */
	final operands:Array<Int> = [];

	inline function put0():Void
		operands.resize(0);

	inline function put1(a:Int):Void {
		operands.resize(0);
		operands.push(a);
	}

	inline function put2(a:Int, b:Int):Void {
		operands.resize(0);
		operands.push(a);
		operands.push(b);
	}

	inline function put3(a:Int, b:Int, c:Int):Void {
		put2(a, b);
		operands.push(c);
	}

	inline function put4(a:Int, b:Int, c:Int, d:Int):Void {
		put3(a, b, c);
		operands.push(d);
	}

	/** `destination, target, arguments.length, ...arguments` */
	function putCall(destination:Int, target:Int, arguments:Array<Int>):Void {
		put3(destination, target, arguments.length);
		for (argument in arguments)
			operands.push(argument);
	}

	/** Lowers the instruction at `position` into `opcode` and the operands left in `operands`; nothing is allocated per instruction. */
	function lowerInstruction(instruction:HlInstruction, position:Int, labels:Map<String, Int>):HlOpcode {
		return switch instruction {
			case Move(destination, source): {put2(destination, source); HlOpcode.Mov;}
			case LoadInt(destination, constant):
				{put2(destination, constant); HlOpcode.Int;}
			case LoadFloat(destination, constant):
				{put2(destination, constant); HlOpcode.Float;}
			case LoadString(destination, constant):
				{put2(destination, constant); HlOpcode.String;}
			case LoadBool(destination, value):
				{put2(destination, value ? 1 : 0); HlOpcode.Bool;}
			case LoadNull(destination):
				{put1(destination); HlOpcode.Null;}
			case LoadType(destination, type):
				{put2(destination, type); HlOpcode.Type;}
			case ToDyn(destination, source):
				{put2(destination, source); HlOpcode.ToDyn;}
			case ToSFloat(destination, source):
				{put2(destination, source); HlOpcode.ToSFloat;}
			case ToInt(destination, source):
				{put2(destination, source); HlOpcode.ToInt;}
			case UnsafeCast(destination, source):
				{put2(destination, source); HlOpcode.UnsafeCast;}
			case Ref(destination, source):
				{put2(destination, source); HlOpcode.Ref;}
			case Unref(destination, source):
				{put2(destination, source); HlOpcode.Unref;}
			case Setref(destination, source):
				{put2(destination, source); HlOpcode.Setref;}
			case RefOffset(destination, source, index):
				{put3(destination, source, index); HlOpcode.RefOffset;}
			case SafeCast(destination, source):
				{put2(destination, source); HlOpcode.SafeCast;}
			case GlobalGet(destination, global):
				{put2(destination, global); HlOpcode.GetGlobal;}
			case GlobalSet(global, source):
				{put2(global, source); HlOpcode.SetGlobal;}
			case Add(destination, left, right):
				{put3(destination, left, right); HlOpcode.Add;}
			case Sub(destination, left, right):
				{put3(destination, left, right); HlOpcode.Sub;}
			case Mul(destination, left, right): {put3(destination, left, right); HlOpcode.Mul;}
			case Div(destination, left, right): {put3(destination, left, right); HlOpcode.SDiv;}
			case Mod(destination, left, right): {put3(destination, left, right); HlOpcode.SMod;}
			case BitAnd(destination, left, right): {put3(destination, left, right); HlOpcode.And;}
			case BitXor(destination, left, right): {put3(destination, left, right); HlOpcode.Xor;}
			case BitOr(destination, left, right): {put3(destination, left, right); HlOpcode.Or;}
			case ShiftLeft(destination, left, right): {put3(destination, left, right); HlOpcode.Shl;}
			case ShiftRight(destination, left, right): {put3(destination, left, right); HlOpcode.SShr;}
			case UnsignedShiftRight(destination, left, right): {put3(destination, left, right); HlOpcode.UShr;}
			case Call0(destination, functionIndex):
				{put2(destination, functionIndex); HlOpcode.Call0;}
			case Call1(destination, functionIndex, argument):
				{put3(destination, functionIndex, argument); HlOpcode.Call1;}
			case Call2(destination, functionIndex, argument1, argument2):
				{put4(destination, functionIndex, argument1, argument2); HlOpcode.Call2;}
			case CallN(destination, functionIndex, arguments):
				{putCall(destination, functionIndex, arguments); HlOpcode.CallN;}
			case StaticClosure(destination, functionIndex):
				{put2(destination, functionIndex); HlOpcode.StaticClosure;}
			case InstanceClosure(destination, functionIndex, receiver):
				{put3(destination, functionIndex, receiver); HlOpcode.InstanceClosure;}
			case NullCheck(register):
				{put1(register); HlOpcode.NullCheck;}
			case CallClosure(destination, closure, arguments):
				{putCall(destination, closure, arguments); HlOpcode.CallClosure;}
			case ToVirtual(destination, source):
				{put2(destination, source); HlOpcode.ToVirtual;}
			case CallMethod(destination, method, arguments):
				{putCall(destination, method, arguments); HlOpcode.CallMethod;}
			case New(destination, _, _):
				// ONew has no encoded type operand. HashLink derives the
				// allocation type from the destination register's type.
				{put1(destination); HlOpcode.New;}
			case FieldGet(destination, object, field):
				{put3(destination, object, field); HlOpcode.Field;}
			case FieldSet(object, field, source):
				{put3(object, field, source); HlOpcode.SetField;}
			case ArrayGet(destination, array, index):
				{put3(destination, array, index); HlOpcode.GetArray;}
			case ArraySet(array, index, source):
				{put3(array, index, source); HlOpcode.SetArray;}
			case GetI8(destination, pointer, offset):
				{put3(destination, pointer, offset); HlOpcode.GetI8;}
			case GetI16(destination, pointer, offset):
				{put3(destination, pointer, offset); HlOpcode.GetI16;}
			case GetMem(destination, pointer, offset):
				{put3(destination, pointer, offset); HlOpcode.GetMem;}
			case SetI8(pointer, offset, source):
				{put3(pointer, offset, source); HlOpcode.SetI8;}
			case SetI16(pointer, offset, source):
				{put3(pointer, offset, source); HlOpcode.SetI16;}
			case SetMem(pointer, offset, source):
				{put3(pointer, offset, source); HlOpcode.SetMem;}
			case ArraySize(destination, array):
				{put2(destination, array); HlOpcode.ArraySize;}
			case RefData(destination, array):
				{put2(destination, array); HlOpcode.RefData;}
			case MakeEnum(destination, constructor, arguments):
				{putCall(destination, constructor, arguments); HlOpcode.MakeEnum;}
			case EnumIndex(destination, value):
				{put2(destination, value); HlOpcode.EnumIndex;}
			case EnumField(destination, value, constructor, field):
				{put4(destination, value, constructor, field); HlOpcode.EnumField;}
			case JumpSignedLessOrEqual(left, right, target):
				var targetPosition = requireLabel(labels, target);
				{put3(left, right, targetPosition - (position + 1)); HlOpcode.JSLte;}
			case JumpSignedLess(left, right, target):
				var targetPosition = requireLabel(labels, target);
				{put3(left, right, targetPosition - (position + 1)); HlOpcode.JSLt;}
			case JumpUnsignedLess(left, right, target):
				var targetPosition = requireLabel(labels, target);
				{put3(left, right, targetPosition - (position + 1)); HlOpcode.JULt;}
			case JumpNull(value, target):
				var targetPosition = requireLabel(labels, target);
				{put2(value, targetPosition - (position + 1)); HlOpcode.JNull;}
			case JumpEqual(left, right, target):
				var targetPosition = requireLabel(labels, target);
				{put3(left, right, targetPosition - (position + 1)); HlOpcode.JEq;}
			case JumpTrue(condition, target):
				var targetPosition = requireLabel(labels, target);
				{put2(condition, targetPosition - (position + 1)); HlOpcode.JTrue;}
			case Jump(target):
				var targetPosition = requireLabel(labels, target);
				{put1(targetPosition - (position + 1)); HlOpcode.JAlways;}
			case Trap(destination, target, preserveExceptionStack):
				var targetPosition = requireLabel(labels, target);
				{put2(destination, targetPosition - (position + 1)); preserveExceptionStack == true ? HlOpcode.CleanupTrap : HlOpcode.Trap;}
			case EndTrap(destination, preserveExceptionStack):
				{put1(destination); preserveExceptionStack == true ? HlOpcode.EndCleanupTrap : HlOpcode.EndTrap;}
			case Label(_): {put0(); HlOpcode.Label;}
			case Return(register):
				{put1(register); HlOpcode.Ret;}
			case Throw(register):
				{put1(register); HlOpcode.Throw;}
			case Rethrow(register):
				{put1(register); HlOpcode.Rethrow;}
		};
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
