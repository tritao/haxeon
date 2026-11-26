package compiler.hl;

import compiler.core.InternalError;
import compiler.core.SourceAnchor.SourceAnchors;
import compiler.hl.HlCode.HlDebugSection;
import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.HlFunction.HlDebugLocation;
import compiler.hl.HlFunction.HlInstruction;
import haxe.ds.ObjectMap;
import haxe.io.Bytes as HaxeBytes;
import haxeon.io.ByteSink;
import haxeon.io.SegmentedBytes;
import sys.io.File;

/** The source locations of one function's opcodes, by stable function identity; `locations[i]` belongs to opcode i. */
typedef HlOpcodeSourceSpanGroup = {
	final stableId:Int;
	final locations:Array<HlDebugLocation>;

	/** The function's instructions, which say which of them are written (`HlWriter.layout`). */
	final opcodes:Array<HlInstruction>;
}

/** A debug section's header flags and payload as a module stores them. */
private typedef HlStoredSection = {
	final flags:Int;
	final payload:SegmentedBytes;
}

/** Serializes the in-memory HashLink model using canonical HLB encodings. */
@:allow(compiler.hl.HlSectionWriter)
class HlWriter {
	public static inline final FUNCTION_IDENTITIES = 1;
	public static inline final OPCODE_SOURCE_SPANS = 2;
	public static inline final SOURCE_SNAPSHOTS = 3;

	/** A debug section flag: the payload is its decoded size (an unsigned index) followed by one LZ4 block (HlLz4). */
	public static inline final COMPRESSED = 1;

	final output:ByteSink = new ByteSink();
	final cache:Null<HlWriterCache>;
	var hasDebug:Bool = false;
	var debugFiles:Array<String> = [];
	var debugFileIndices:Map<String, Int> = [];

	/** Where the module's debug locations count from (`HlCode.sources`). */
	var sources:SourceAnchors = new SourceAnchors([]);

	/** By anchor id, the index of its file in `debugFiles` once looked up, else -1. */
	var anchorFiles:Array<Int> = [];

	var functionScratch:Null<HlFunctionScratch>;

	/** In a module section, the section's index of each table entry the functions name (`HlSectionWriter`); null in a dense module. */
	var local:Null<HlSectionIndices>;

	public function new(?cache:HlWriterCache) {
		this.cache = cache;
	}

	/** Appends bytes that are never changed again (the cached prefix, cached function encodings, section payloads) without copying them. */
	function writeShared(bytes:HaxeBytes):Void
		output.appendShared(bytes);

	/** What this writer wrote, as one buffer: for the small results (an index, a function, a section header). */
	function bytes():HaxeBytes
		return output.finish().flatten();

	/**
	 * The module as segments: the cached encodings of unchanged functions are shared, not copied. `checkReuse` adds the validator's
	 * consistency checks of what it reuses (`CompileOptions.checkReuse`).
	 */
	public static function encode(code:HlCode, ?cache:HlWriterCache, checkReuse:Bool = false):SegmentedBytes {
		if (code.relocations != null)
			throw new compiler.core.InternalError("A sectioned build's module is written as sections");
		HlValidator.validate(code, cache, checkReuse);
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
		} catch (error:haxe.Exception) {
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
				+ '}'
		];
		var topStrings = [
			for (entry in stringSizes.slice(0, 30))
				'{"index":'
				+ entry.index
				+ ',"bytes":'
				+ entry.bytes
				+ ',"value":'
				+ haxe.Json.stringify(code.strings[entry.index])
				+ '}'
		];
		var uses:Map<Int, Int> = [];
		for (fn in code.functions)
			for (opcode in fn.opcodes)
				switch opcode {
					case LoadString(_, index):
						uses.set(index, (uses.exists(index) ? uses.get(index) : 0) + 1);
					default:
				}
		var stringUses = [for (index => count in uses) {
			index: index, count: count
		}];
		stringUses.sort((a, b) -> a.count != b.count ? b.count - a.count : a.index - b.index);
		var topStringUses = [
			for (entry in stringUses.slice(0, 30))
				'{"index":'
				+ entry.index
				+ ',"references":'
				+ entry.count
				+ ',"value":'
				+ haxe.Json.stringify(code.strings[entry.index])
				+ '}'
		];
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
				+ storedSection(section, null).payload.length
				+ ',"decoded":'
				+ section.payload.length
				+ '}'
		];
		var scalarConstants = code.ints.length * 4 + code.floats.length * 8;
		var header = prefix - strings - debugFiles - types - globals - natives - scalarConstants;
		Sys.stderr()
			.writeString('SIZE_CENSUS {"target":"hl","header":' + header + ',"scalarConstants":' + scalarConstants
			+ ',"strings":' + strings
			+ ',"debugFiles":' + debugFiles + ',"types":' + (types - reflection) + ',"reflectionMembers":' + reflection
			+ ',"globals":' + globals
			+ ',"natives":' + natives + ',"functions":' + functions + ',"functionDebug":' + functionDebug
			+ ',"constants":' + constants
			+ ',"debugSections":' + debugSections + ',"sections":[' + sections.join(",") + '],"topTypes":['
			+ topTypes.join(",") + '],"topStrings":['
			+ topStrings.join(",") + '],"topStringUses":[' + topStringUses.join(",") + '],"topFunctionDebug":['
			+ topFunctionDebug.join(",") + ']}\n');
	}

	function writePrefixWithDebug(code:HlCode, prepared:HlWriter):Void {
		hasDebug = prepared.hasDebug;
		debugFiles = prepared.debugFiles;
		debugFileIndices = prepared.debugFileIndices;
		sources = prepared.sources;
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
			// Without a cache nothing keeps a function's encoding, so it is written in place.
			if (cache == null) {
				writeFunction(fn);
				continue;
			}
			var encoded = cache.get(fn, sources);
			if (encoded == null) {
				encoded = encodePreparedFunction(fn);
				cache.set(fn, encoded, hasDebug ? sources : null);
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
		writer.sources = sources;
		writer.anchorFiles = anchorFiles;
		writer.functionScratch = scratch();
		writer.writeFunction(fn);
		return writer.bytes();
	}

	function writeDebugSections(code:HlCode):Void {
		writeUnsignedIndex(code.debugSections.length);
		for (section in code.debugSections) {
			if (section.kind <= 0 || section.version <= 0 || section.flags < 0)
				throw new InternalError("Invalid HLB debug section header");
			var stored = storedSection(section, cache);
			writeUnsignedIndex(section.kind);
			writeUnsignedIndex(section.version);
			writeUnsignedIndex(stored.flags);
			writeUnsignedIndex(stored.payload.length);
			output.appendSegments(stored.payload);
		}
	}

	/**
	 * A section's header flags and payload as the module stores them: compressed when it asks to be and the natives are there. With a
	 * cache, a payload the same as last time's is not compressed again.
	 */
	static function storedSection(section:HlDebugSection, cache:Null<HlWriterCache>):HlStoredSection {
		var payload = section.payloadFor(cache), level = section.compression;
		if (level == null)
			return {flags: section.flags, payload: payload};
		var decoded = payload.flatten();
		var known = cache == null ? null : cache.compressedSection(section.kind, level, decoded);
		if (known != null)
			return {flags: section.flags | COMPRESSED, payload: known};
		var block = HlLz4.compress(decoded, level);
		if (block == null)
			return {flags: section.flags, payload: payload};
		var writer = new HlWriter();
		writer.writeUnsignedIndex(decoded.length);
		writer.writeShared(block);
		var stored = writer.output.finish();
		if (cache != null)
			cache.setCompressedSection(section.kind, level, decoded, stored);
		return {flags: section.flags | COMPRESSED, payload: stored};
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
	 * as every file it names has the same index and every anchor it names the same place in `sources`; only the changed functions
	 * are encoded.
	 */
	public static function encodeOpcodeSourceSpanGroups(groups:Array<HlOpcodeSourceSpanGroup>, sources:SourceAnchors,
			?cache:HlWriterCache):SegmentedBytes {
		var writer = new HlWriter(),
			files:Array<String> = [],
			fileIndices:Map<String, Int> = [],
			seenFunctions:Map<Int, Bool> = [];
		writer.sources = sources;
		var previousAnchor = -1;
		for (group in groups) {
			if (group.stableId < 0 || seenFunctions.exists(group.stableId))
				throw new InternalError("Invalid HLB opcode source-span function");
			seenFunctions.set(group.stableId, true);
			for (location in group.locations) {
				var validRange = location.start == -1 && location.end == -1 || location.start >= 0
					&& location.end >= location.start;
				if (location.line < 0
					|| location.column < 1
					|| location.endLine < location.line
					|| location.endColumn < 1
					|| location.endLine == location.line
					&& location.endColumn < location.column
					|| location.flags < 0
					|| !validRange)
					throw new InternalError("Invalid HLB opcode source span");
				if (location.anchor != previousAnchor) {
					previousAnchor = location.anchor;
					var path = sources.path(previousAnchor), fileIndex = fileIndices.get(path);
					if (fileIndex == null) {
						if (path == "")
							throw new InternalError("Invalid HLB opcode source span");
						fileIndex = files.length;
						fileIndices.set(path, fileIndex);
						files.push(path);
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
			var cached = cache == null ? null : cache.spanGroup(group.locations, group.stableId, fileIndices, sources);
			if (cached == null) {
				var groupWriter = new HlWriter();
				groupWriter.sources = sources;
				groupWriter.writeSpanGroup(group, fileIndices);
				cached = groupWriter.bytes();
				if (cache != null)
					cache.setSpanGroup(group.locations, group.stableId, cached, fileIndices, sources);
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
		var positions = scratch().positions;
		layoutInto(group.opcodes, positions, scratch().labelIndices, scratch().loopHeads);
		writeUnsignedIndex(group.stableId);
		writeUnsignedIndex(positions[group.opcodes.length]);
		var previousAnchor = -1, previousFileIndex = -1, offset = 0, line = 0, hash = 0;
		for (index in 0...group.locations.length) {
			if (positions[index + 1] == positions[index])
				continue;
			var location = group.locations[index];
			writeUnsignedIndex(positions[index]);
			if (location.anchor != previousAnchor) {
				previousAnchor = location.anchor;
				previousFileIndex = cast fileIndices.get(sources.path(previousAnchor));
				offset = sources.offset(previousAnchor);
				line = sources.line(previousAnchor);
				hash = sources.hash(previousAnchor);
			}
			writeUnsignedIndex(previousFileIndex);
			writeIndex(location.start < 0 ? 0 : offset + location.start + 1);
			writeIndex(location.end < 0 ? 0 : offset + location.end + 1);
			writeUnsignedIndex(line + location.line);
			writeUnsignedIndex(location.column);
			writeUnsignedIndex(line + location.endLine);
			writeUnsignedIndex(location.endColumn);
			output.writeInt32(location.generatedText ? 0 : hash);
			writeUnsignedIndex(location.flags);
		}
	}

	public static function encodeSourceSnapshots(snapshots:Array<compiler.hl.HlCode.HlSourceSnapshot>):SegmentedBytes {
		var writer = new HlWriter(),
			ordered = snapshots.copy(),
			seen:Map<Int, HaxeBytes> = [];
		ordered.sort((left, right) -> left.sourceHash < right.sourceHash ? -1 : left.sourceHash > right.sourceHash
			? 1 : 0);
		writer.writeUnsignedIndex(ordered.length);
		for (snapshot in ordered) {
			if (snapshot.sourceHash == 0 || seen.exists(snapshot.sourceHash))
				throw new InternalError("Invalid HLB source snapshot");
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
					throw new InternalError("HashLink String cannot contain NUL; use Bytes for binary data");
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
					throw new InternalError('Unsupported parameterized HashLink type $kind');
				output.writeByte(kind);
				writeIndex(parameter);
			case Abstract(name):
				output.writeByte(HlType.Abstract);
				writeIndex(name);
			case Function(arguments, result), Method(arguments, result):
				if (arguments.length > 255)
					throw new InternalError("HL function types support at most 255 arguments");
				output.writeByte(type.match(Method(_, _)) ? HlType.Method : HlType.Fun);
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

	function writeObjectType(name:Int, base:Int, global:Int, fields:Array<compiler.hl.HlCode.HlObjectField>,
			methods:Array<compiler.hl.HlCode.HlObjectMethod>,
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

	function writeObjectMembers(fields:Array<compiler.hl.HlCode.HlObjectField>,
			methods:Array<compiler.hl.HlCode.HlObjectMethod>, bindings:Array<Int>):Void {
		writeFields(fields);
		for (method in methods) {
			writeIndex(method.name);
			writeUnsignedIndex(method.functionIndex);
			writeIndex(method.prototype);
		}
		for (binding in bindings)
			writeUnsignedIndex(binding);
	}

	/**
	 * Where each of a function's instructions lands in what HashLink is given: `positions[i]` for instruction `i`, or, when `i` is
	 * left out, for the instruction written after it; `positions[opcodes.length]` is how many are written. Only labels are left out,
	 * those no jump at or after them lands on: the VM needs a label where a loop is entered again and finds every other jump target
	 * from the jump. Everything that names an instruction by position (jumps, debug lines, assignments, opcode spans, patch
	 * relocations) uses these positions.
	 */
	public static function layout(opcodes:Array<HlInstruction>):Array<Int> {
		var positions:Array<Int> = [];
		layoutInto(opcodes, positions, [], []);
		return positions;
	}

	/**
	 * `layout` into `positions`, leaving in `labelIndices` the instruction index of each label by id (-1 for an id no label has);
	 * all three arrays are overwritten, so a writer reuses them for every function.
	 */
	static function layoutInto(opcodes:Array<HlInstruction>, positions:Array<Int>, labelIndices:Array<Int>,
			loopHeads:Array<Bool>):Void {
		var labelCount = 0;
		for (instruction in opcodes)
			switch instruction {
				case Label(id):
					if (id < 0)
						throw new InternalError('Negative HashLink label $id');
					if (id >= labelCount)
						labelCount = id + 1;
				default:
			}
		labelIndices.resize(labelCount);
		loopHeads.resize(labelCount);
		for (id in 0...labelCount) {
			labelIndices[id] = -1;
			loopHeads[id] = false;
		}
		for (index in 0...opcodes.length)
			switch opcodes[index] {
				case Label(id):
					labelIndices[id] = index;
				default:
			}
		for (index in 0...opcodes.length) {
			var target = jumpTarget(opcodes[index]);
			if (target >= 0 && target < labelCount) {
				var label = labelIndices[target];
				if (label >= 0 && label <= index)
					loopHeads[target] = true;
			}
		}
		positions.resize(opcodes.length + 1);
		var written = 0;
		for (index in 0...opcodes.length) {
			positions[index] = written;
			switch opcodes[index] {
				case Label(id) if (!loopHeads[id]):
				default:
					written++;
			}
		}
		positions[opcodes.length] = written;
	}

	/** Every label `instruction` can transfer to: a jump's or trap's one, each of a switch's. */
	public static function jumpTargets(instruction:HlInstruction):Array<Int>
		return switch instruction {
			case Switch(_, targets): targets;
			default:
				var target = jumpTarget(instruction);
				target < 0 ? [] : [target];
		};

	/** Whether `instruction` can transfer control to a label: `jumpTargets` is not empty, without building it. */
	public static function jumps(instruction:HlInstruction):Bool
		return switch instruction {
			case Switch(_, targets): targets.length > 0;
			default: jumpTarget(instruction) >= 0;
		};

	/** The label a jump or trap names, or -1 for any other instruction (a switch names several: `jumpTargets`). */
	public static function jumpTarget(instruction:HlInstruction):Int
		return switch instruction {
			case JumpSignedLessOrEqual(_, _, target), JumpSignedLess(_, _, target), JumpUnsignedLess(_, _, target),
				JumpNull(_, target), JumpEqual(_, _, target), JumpTrue(_, target), Jump(target), Trap(_, target, _),
				JumpFalse(_, target), JumpNotNull(_, target), JumpNotEqual(_, _, target), JumpNotLess(_, _, target),
				JumpNotGreaterOrEqual(_, _, target), JumpSignedGreaterOrEqual(_, _, target),
				JumpSignedGreater(_, _, target),
				JumpUnsignedGreaterOrEqual(_, _, target): target;
			default: -1;
		};

	function scratch():HlFunctionScratch {
		if (functionScratch == null)
			functionScratch = new HlFunctionScratch();
		return functionScratch;
	}

	function writeFunction(fn:HlFunction):Void {
		var scratch = scratch(), positions = scratch.positions;
		layoutInto(fn.opcodes, positions, scratch.labelIndices, scratch.loopHeads);
		var count = fn.opcodes.length, local = this.local;
		// A section's function is named by its head, not by its body.
		if (local == null) {
			writeIndex(fn.type);
			writeUnsignedIndex(fn.functionIndex);
		}
		writeUnsignedIndex(fn.registers.length);
		writeUnsignedIndex(positions[count]);
		for (type in fn.registers)
			writeIndex(local == null ? type : local.types[type]);
		for (index in 0...count) {
			if (positions[index + 1] == positions[index])
				continue;
			var opcode = lowerInstruction(fn.opcodes[index], positions[index], scratch);
			HlOpcodeSchema.validate(opcode, operands);
			writeOpcode(opcode, operands);
		}
		if (hasDebug) {
			writeDebugLocations(fn, positions, scratch.located);
			writeUnsignedIndex(fn.debugAssignments.length);
			for (assignment in fn.debugAssignments) {
				writeUnsignedIndex(local == null ? assignment.name : local.strings[assignment.name]);
				writeIndex(assignment.position < 0 ? 0 : positions[assignment.position] + 1);
				writeIndex(assignment.scopeEnd < 0 ? 0 : positions[assignment.scopeEnd] + 1);
			}
		}
	}

	function prepareDebugFiles(code:HlCode):Void {
		sources = code.sources;
		hasDebug = false;
		for (fn in code.functions)
			if (fn.debugLocations.length > 0)
				hasDebug = true;
		if (!hasDebug)
			return;
		for (fn in code.functions) {
			if (fn.debugLocations.length == 0) {
				internDebugFile("<generated>");
				continue;
			}
			if (cache == null) {
				for (location in fn.debugLocations)
					internDebugFile(sources.path(location.anchor));
				continue;
			}
			// An anchor is always in the same file: a function a session writes again names the files its anchors are in.
			for (anchor in fn.anchors())
				internDebugFile(sources.path(anchor));
		}
	}

	function internDebugFile(path:String):Int {
		if (debugFileIndices.exists(path))
			return debugFileIndices.get(path);
		var index = debugFiles.length;
		if (index > 0x7FFF)
			throw new InternalError("Too many HashLink debug files");
		debugFiles.push(path);
		debugFileIndices.set(path, index);
		return index;
	}

	/** The location of a function that was given none. */
	static final generatedLocation = HlDebugLocation.inFile("<generated>", 1, 1, 1, 1, -1, -1, 1);

	/** The index in `debugFiles` of the file `anchor` is in. */
	function anchorFile(anchor:Int):Int {
		if (anchor < anchorFiles.length && anchorFiles[anchor] >= 0)
			return anchorFiles[anchor];
		var path = sources.path(anchor), file = debugFileIndices.get(path);
		if (file == null)
			throw new InternalError('Missing HashLink debug file index for "$path"');
		while (anchorFiles.length <= anchor)
			anchorFiles.push(-1);
		anchorFiles[anchor] = file;
		return file;
	}

	function writeDebugLocations(fn:HlFunction, positions:Array<Int>, located:Array<HlDebugLocation>):Void {
		located.resize(0);
		for (index in 0...fn.opcodes.length)
			if (positions[index + 1] != positions[index])
				located.push(fn.debugLocations.length == 0 ? generatedLocation : fn.debugLocations[index]);
		var currentFile = -1, currentLine = 0, index = 0;
		while (index < located.length) {
			var location:HlDebugLocation = located[index],
				line = sources.line(location.anchor) + location.line;
			if (line > 0x1FFFFF)
				throw new InternalError('Debug line $line exceeds the HashLink format limit');
			var file = anchorFile(location.anchor);
			if (file != currentFile) {
				output.writeByte(((file >> 8) << 1) | 1);
				output.writeByte(file & 0xFF);
				currentFile = file;
			}
			if (line == currentLine) {
				var count = 1;
				while (count < 15 && index + count < located.length) {
					var next = located[index + count];
					if (anchorFile(next.anchor) != file || sources.line(next.anchor) + next.line != currentLine)
						break;
					count++;
				}
				output.writeByte((count << 2) | 2);
				index += count;
			} else {
				var delta = line - currentLine;
				if (delta > 0 && delta <= 31)
					output.writeByte((delta << 3) | 4);
				else {
					output.writeByte((line & 0x1F) << 3);
					output.writeByte((line >> 5) & 0xFF);
					output.writeByte((line >> 13) & 0xFF);
				}
				currentLine = line;
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
	function lowerInstruction(instruction:HlInstruction, position:Int, scratch:HlFunctionScratch):HlOpcode {
		var local = this.local;
		return switch instruction {
			case Move(destination, source): {
				put2(destination, source);
				HlOpcode.Mov;
			}
			case LoadInt(destination, constant):
				{
					put2(destination, local == null ? constant : local.ints[constant]);
					HlOpcode.Int;
				}
			case LoadFloat(destination, constant):
				{
					put2(destination, local == null ? constant : local.floats[constant]);
					HlOpcode.Float;
				}
			case LoadString(destination, constant):
				{
					put2(destination, local == null ? constant : local.strings[constant]);
					HlOpcode.String;
				}
			case LoadBool(destination, value):
				{
					put2(destination, value ? 1 : 0);
					HlOpcode.Bool;
				}
			case LoadNull(destination):
				{
					put1(destination);
					HlOpcode.Null;
				}
			case LoadType(destination, type):
				{
					put2(destination, local == null ? type : local.types[type]);
					HlOpcode.Type;
				}
			case ToDyn(destination, source):
				{
					put2(destination, source);
					HlOpcode.ToDyn;
				}
			case GetType(destination, source):
				{
					put2(destination, source);
					HlOpcode.GetType;
				}
			case ToSFloat(destination, source):
				{
					put2(destination, source);
					HlOpcode.ToSFloat;
				}
			case ToInt(destination, source):
				{
					put2(destination, source);
					HlOpcode.ToInt;
				}
			case UnsafeCast(destination, source):
				{
					put2(destination, source);
					HlOpcode.UnsafeCast;
				}
			case Ref(destination, source):
				{
					put2(destination, source);
					HlOpcode.Ref;
				}
			case Unref(destination, source):
				{
					put2(destination, source);
					HlOpcode.Unref;
				}
			case Setref(destination, source):
				{
					put2(destination, source);
					HlOpcode.Setref;
				}
			case RefOffset(destination, source, index):
				{
					put3(destination, source, index);
					HlOpcode.RefOffset;
				}
			case SafeCast(destination, source):
				{
					put2(destination, source);
					HlOpcode.SafeCast;
				}
			case GlobalGet(destination, global):
				{
					put2(destination, local == null ? global : local.globals[global]);
					HlOpcode.GetGlobal;
				}
			case GlobalSet(global, source):
				{
					put2(local == null ? global : local.globals[global], source);
					HlOpcode.SetGlobal;
				}
			case Add(destination, left, right):
				{
					put3(destination, left, right);
					HlOpcode.Add;
				}
			case Sub(destination, left, right):
				{
					put3(destination, left, right);
					HlOpcode.Sub;
				}
			case Mul(destination, left, right): {
				put3(destination, left, right);
				HlOpcode.Mul;
			}
			case Div(destination, left, right): {
				put3(destination, left, right);
				HlOpcode.SDiv;
			}
			case Mod(destination, left, right): {
				put3(destination, left, right);
				HlOpcode.SMod;
			}
			case BitAnd(destination, left, right): {
				put3(destination, left, right);
				HlOpcode.And;
			}
			case BitXor(destination, left, right): {
				put3(destination, left, right);
				HlOpcode.Xor;
			}
			case BitOr(destination, left, right): {
				put3(destination, left, right);
				HlOpcode.Or;
			}
			case ShiftLeft(destination, left, right): {
				put3(destination, left, right);
				HlOpcode.Shl;
			}
			case ShiftRight(destination, left, right): {
				put3(destination, left, right);
				HlOpcode.SShr;
			}
			case UnsignedShiftRight(destination, left, right): {
				put3(destination, left, right);
				HlOpcode.UShr;
			}
			case Call0(destination, functionIndex):
				{
					put2(destination, local == null ? functionIndex : local.functions[functionIndex]);
					HlOpcode.Call0;
				}
			case Call1(destination, functionIndex, argument):
				{
					put3(destination, local == null ? functionIndex : local.functions[functionIndex], argument);
					HlOpcode.Call1;
				}
			case Call2(destination, functionIndex, argument1, argument2):
				{
					put4(destination, local == null ? functionIndex : local.functions[functionIndex], argument1,
						argument2);
					HlOpcode.Call2;
				}
			case CallN(destination, functionIndex, arguments):
				{
					putCall(destination, local == null ? functionIndex : local.functions[functionIndex], arguments);
					HlOpcode.CallN;
				}
			case StaticClosure(destination, functionIndex):
				{
					put2(destination, local == null ? functionIndex : local.functions[functionIndex]);
					HlOpcode.StaticClosure;
				}
			case InstanceClosure(destination, functionIndex, receiver):
				{
					put3(destination, local == null ? functionIndex : local.functions[functionIndex], receiver);
					HlOpcode.InstanceClosure;
				}
			case NullCheck(register):
				{
					put1(register);
					HlOpcode.NullCheck;
				}
			case CallClosure(destination, closure, arguments):
				{
					putCall(destination, closure, arguments);
					HlOpcode.CallClosure;
				}
			case ToVirtual(destination, source):
				{
					put2(destination, source);
					HlOpcode.ToVirtual;
				}
			case CallMethod(destination, method, arguments):
				{
					putCall(destination, method, arguments);
					HlOpcode.CallMethod;
				}
			case New(destination, _, _):
				// ONew has no encoded type operand. HashLink derives the
				// allocation type from the destination register's type.
				{
					put1(destination);
					HlOpcode.New;
				}
			case FieldGet(destination, object, field):
				{
					put3(destination, object, field);
					HlOpcode.Field;
				}
			case FieldSet(object, field, source):
				{
					put3(object, field, source);
					HlOpcode.SetField;
				}
			case ArrayGet(destination, array, index):
				{
					put3(destination, array, index);
					HlOpcode.GetArray;
				}
			case ArraySet(array, index, source):
				{
					put3(array, index, source);
					HlOpcode.SetArray;
				}
			case GetI8(destination, pointer, offset):
				{
					put3(destination, pointer, offset);
					HlOpcode.GetI8;
				}
			case GetI16(destination, pointer, offset):
				{
					put3(destination, pointer, offset);
					HlOpcode.GetI16;
				}
			case GetMem(destination, pointer, offset):
				{
					put3(destination, pointer, offset);
					HlOpcode.GetMem;
				}
			case SetI8(pointer, offset, source):
				{
					put3(pointer, offset, source);
					HlOpcode.SetI8;
				}
			case SetI16(pointer, offset, source):
				{
					put3(pointer, offset, source);
					HlOpcode.SetI16;
				}
			case SetMem(pointer, offset, source):
				{
					put3(pointer, offset, source);
					HlOpcode.SetMem;
				}
			case ArraySize(destination, array):
				{
					put2(destination, array);
					HlOpcode.ArraySize;
				}
			case RefData(destination, array):
				{
					put2(destination, array);
					HlOpcode.RefData;
				}
			case MakeEnum(destination, constructor, arguments):
				{
					putCall(destination, constructor, arguments);
					HlOpcode.MakeEnum;
				}
			case EnumIndex(destination, value):
				{
					put2(destination, value);
					HlOpcode.EnumIndex;
				}
			case EnumField(destination, value, constructor, field):
				{
					put4(destination, value, constructor, field);
					HlOpcode.EnumField;
				}
			case JumpSignedLessOrEqual(left, right, target):
				var targetPosition = scratch.labelPosition(target);
				{
					put3(left, right, targetPosition - (position + 1));
					HlOpcode.JSLte;
				}
			case JumpSignedLess(left, right, target):
				var targetPosition = scratch.labelPosition(target);
				{
					put3(left, right, targetPosition - (position + 1));
					HlOpcode.JSLt;
				}
			case JumpUnsignedLess(left, right, target):
				var targetPosition = scratch.labelPosition(target);
				{
					put3(left, right, targetPosition - (position + 1));
					HlOpcode.JULt;
				}
			case JumpNull(value, target):
				var targetPosition = scratch.labelPosition(target);
				{
					put2(value, targetPosition - (position + 1));
					HlOpcode.JNull;
				}
			case JumpEqual(left, right, target):
				var targetPosition = scratch.labelPosition(target);
				{
					put3(left, right, targetPosition - (position + 1));
					HlOpcode.JEq;
				}
			case JumpTrue(condition, target):
				var targetPosition = scratch.labelPosition(target);
				{
					put2(condition, targetPosition - (position + 1));
					HlOpcode.JTrue;
				}
			case JumpFalse(condition, target):
				var targetPosition = scratch.labelPosition(target);
				{
					put2(condition, targetPosition - (position + 1));
					HlOpcode.JFalse;
				}
			case JumpNotNull(value, target):
				var targetPosition = scratch.labelPosition(target);
				{
					put2(value, targetPosition - (position + 1));
					HlOpcode.JNotNull;
				}
			case JumpNotEqual(left, right, target):
				var targetPosition = scratch.labelPosition(target);
				{
					put3(left, right, targetPosition - (position + 1));
					HlOpcode.JNotEq;
				}
			case JumpNotLess(left, right, target):
				var targetPosition = scratch.labelPosition(target);
				{
					put3(left, right, targetPosition - (position + 1));
					HlOpcode.JNotLt;
				}
			case JumpNotGreaterOrEqual(left, right, target):
				var targetPosition = scratch.labelPosition(target);
				{
					put3(left, right, targetPosition - (position + 1));
					HlOpcode.JNotGte;
				}
			case JumpSignedGreaterOrEqual(left, right, target):
				var targetPosition = scratch.labelPosition(target);
				{
					put3(left, right, targetPosition - (position + 1));
					HlOpcode.JSGte;
				}
			case JumpUnsignedGreaterOrEqual(left, right, target):
				var targetPosition = scratch.labelPosition(target);
				{
					put3(left, right, targetPosition - (position + 1));
					HlOpcode.JUGte;
				}
			case JumpSignedGreater(left, right, target):
				var targetPosition = scratch.labelPosition(target);
				{
					put3(left, right, targetPosition - (position + 1));
					HlOpcode.JSGt;
				}
			case Switch(value, targets):
				operands.resize(0);
				operands.push(value);
				operands.push(targets.length);
				for (target in targets)
					operands.push(scratch.labelPosition(target) - (position + 1));
				operands.push(0);
				HlOpcode.Switch;
			case Jump(target):
				var targetPosition = scratch.labelPosition(target);
				{
					put1(targetPosition - (position + 1));
					HlOpcode.JAlways;
				}
			case Trap(destination, target, preserveExceptionStack):
				var targetPosition = scratch.labelPosition(target);
				{
					put2(destination, targetPosition - (position + 1));
					preserveExceptionStack == true ? HlOpcode.CleanupTrap : HlOpcode.Trap;
				}
			case EndTrap(destination, preserveExceptionStack):
				{
					put1(destination);
					preserveExceptionStack == true ? HlOpcode.EndCleanupTrap : HlOpcode.EndTrap;
				}
			case Label(_): {
				put0();
				HlOpcode.Label;
			}
			case Return(register):
				{
					put1(register);
					HlOpcode.Ret;
				}
			case Throw(register):
				{
					put1(register);
					HlOpcode.Throw;
				}
			case Rethrow(register):
				{
					put1(register);
					HlOpcode.Rethrow;
				}
		};
	}


	function writeOpcode(opcode:HlOpcode, operands:Array<Int>):Void {
		output.writeByte(opcode);
		for (operand in operands)
			writeIndex(operand);
	}

	function writeUnsignedIndex(value:Int):Void {
		if (value < 0)
			throw new InternalError('Expected unsigned index, got $value');
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
			throw new InternalError('HL index is out of range: $value');
		}
	}
}

/** The working arrays of the function being written (see `HlWriter.layout`), reused by every function of a module. */
private class HlFunctionScratch {
	public final positions:Array<Int> = [];
	public final labelIndices:Array<Int> = [];
	public final loopHeads:Array<Bool> = [];
	public final located:Array<HlDebugLocation> = [];

	public function new() {}

	/** The written position of the label `target` in the function laid out last. */
	public function labelPosition(target:Int):Int {
		var index = target >= 0 && target < labelIndices.length ? labelIndices[target] : -1;
		if (index < 0)
			throw new InternalError('Unknown HashLink jump label $target');
		return positions[index];
	}
}

/**
 * By index in a dense module's tables, the index in one module section's tables of each entry the section names
 * (`HlSectionWriter`); an entry the section does not name is unset.
 */
class HlSectionIndices {
	public final ints:Array<Int> = [];
	public final floats:Array<Int> = [];
	public final strings:Array<Int> = [];
	public final types:Array<Int> = [];
	public final globals:Array<Int> = [];
	public final functions:Array<Int> = [];

	public function new() {}
}
