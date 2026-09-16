package compiler.hl.patch;

import haxe.io.Bytes as HaxeBytes;
import haxe.io.BytesOutput;
import compiler.hl.HlWriter;
import compiler.hl.HlCode;
import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.HlFunction;
import compiler.hl.HlType as HashLinkType;

/** Encodes versioned, transactional HLP deltas from an assembled module. */
class HlPatchWriter {
	static inline final SYMBOLS = 1;
	static inline final FUNCTIONS = 2;
	static inline final DEBUG = 3;
	static inline final SOURCE_SNAPSHOTS = 4;

	public static function encode(code:HlCode, moduleId:HaxeBytes, changedSlots:Array<Int>, stableIdsBySlot:Map<Int, Int>, baseRevision:Int, revision:Int,
			baseInts:Int = 0, baseFloats:Int = 0, baseStrings:Int = 0, baseTypes:Int = 0, ?extensionSections:Array<{
			tag:Int,
			bytes:HaxeBytes
		}>):HaxeBytes {
		if (baseRevision < 0 || revision <= baseRevision)
			throw "Invalid patch revision range";
		var selected:Array<HlFunction> = [];
		if (moduleId.length != 16)
			throw "Module ID must contain 16 bytes";
		for (index in changedSlots) {
			var found:Null<HlFunction> = null;
			for (fn in code.functions)
				if (fn.functionIndex == index) {
					found = fn;
					break;
				}
			if (found == null)
				throw 'Patch references missing function $index';
			for (op in found.opcodes)
				switch op {
					case Switch(_, _, _):
						throw "Switch instructions require a structural reload";
					default:
				}
			selected.push(found);
		}
		var symbols = new BytesOutput();
		symbols.bigEndian = false;
		checkBase(baseInts, code.ints.length);
		symbols.writeInt32(HlPatchHashes.ints(code.ints, baseInts));
		writeIndex(symbols, baseInts);
		writeIndex(symbols, code.ints.length - baseInts);
		for (i in baseInts...code.ints.length)
			symbols.writeInt32(code.ints[i]);
		checkBase(baseFloats, code.floats.length);
		symbols.writeInt32(HlPatchHashes.floats(code.floats, baseFloats));
		writeIndex(symbols, baseFloats);
		writeIndex(symbols, code.floats.length - baseFloats);
		for (i in baseFloats...code.floats.length)
			symbols.writeDouble(code.floats[i]);
		checkBase(baseStrings, code.strings.length);
		symbols.writeInt32(HlPatchHashes.strings(code.strings, baseStrings));
		writeIndex(symbols, baseStrings);
		writeIndex(symbols, code.strings.length - baseStrings);
		for (i in baseStrings...code.strings.length) {
			var b = HaxeBytes.ofString(code.strings[i]);
			writeIndex(symbols, b.length);
			symbols.write(b);
		}
		checkBase(baseTypes, code.types.length);
		symbols.writeInt32(HlPatchHashes.types(code.types, baseTypes));
		writeIndex(symbols, baseTypes);
		writeIndex(symbols, code.types.length - baseTypes);
		for (i in baseTypes...code.types.length)
			writeType(symbols, code.types[i]);
		var functions = new BytesOutput();
		functions.bigEndian = false;
		writeIndex(functions, selected.length);
		for (fn in selected) {
			if (!stableIdsBySlot.exists(fn.functionIndex))
				throw 'Missing stable ID for function slot ${fn.functionIndex}';
			var stableId = stableIdsBySlot.get(fn.functionIndex);
			var body = HlWriter.encodeFunction(fn), bytes = new BytesOutput();
			bytes.bigEndian = false;
			writeIndex(bytes, stableId);
			bytes.write(body);
			var relocations = callRelocations(fn, stableIdsBySlot);
			writeIndex(bytes, relocations.length);
			for (relocation in relocations) {
				writeIndex(bytes, relocation.instruction);
				writeIndex(bytes, relocation.stableId);
			}
			var encoded = bytes.getBytes();
			writeIndex(functions, encoded.length);
			functions.write(encoded);
		}
		var out = new BytesOutput();
		var debug = encodeDebug(selected, stableIdsBySlot),
			snapshots = encodeSourceSnapshots(code, selected);
		out.bigEndian = false;
		out.writeString(HlPatchFormat.MAGIC);
		out.writeByte(HlPatchFormat.VERSION);
		out.write(moduleId);
		writeIndex(out, baseRevision);
		writeIndex(out, revision);
		var extensions = extensionSections == null ? [] : extensionSections;
		for (section in extensions)
			if (section.tag == SYMBOLS || section.tag == FUNCTIONS || section.tag == DEBUG || section.tag == SOURCE_SNAPSHOTS)
				throw 'Extension section uses reserved HLP tag ${section.tag}';
		writeIndex(out, 2 + (debug == null ? 0 : 1) + (snapshots == null ? 0 : 1) + extensions.length);
		writeSection(out, SYMBOLS, symbols.getBytes());
		writeSection(out, FUNCTIONS, functions.getBytes());
		if (debug != null)
			writeSection(out, DEBUG, debug);
		if (snapshots != null)
			writeSection(out, SOURCE_SNAPSHOTS, snapshots);
		for (section in extensions)
			writeSection(out, section.tag, section.bytes);
		return out.getBytes();
		}

	static function encodeSourceSnapshots(code:HlCode, functions:Array<HlFunction>):Null<HaxeBytes> {
		var referenced:Map<Int, Bool> = [];
		for (fn in functions)
			for (location in fn.debugLocations)
				if (location.sourceHash != 0)
					referenced.set(location.sourceHash, true);
		var selected = [
			for (snapshot in code.sourceSnapshots)
				if (referenced.exists(snapshot.sourceHash)) snapshot
		];
		return selected.length == 0 ? null : HlWriter.encodeSourceSnapshots(selected);
	}

	static function encodeDebug(functions:Array<HlFunction>, stableIdsBySlot:Map<Int, Int>):Null<HaxeBytes> {
		for (fn in functions)
			if (fn.debugLocations.length == 0)
				return null;
		var files:Array<String> = [], fileIndices:Map<String, Int> = [];
		for (fn in functions)
			for (location in fn.debugLocations)
				if (!fileIndices.exists(location.path)) {
					fileIndices.set(location.path, files.length);
					files.push(location.path);
				}
		var out = new BytesOutput();
		out.bigEndian = false;
		writeIndex(out, files.length);
		for (file in files) {
			var bytes = HaxeBytes.ofString(file);
			writeIndex(out, bytes.length);
			out.write(bytes);
		}
		writeIndex(out, functions.length);
		for (fn in functions) {
			if (fn.debugLocations.length != fn.opcodes.length)
				throw 'Debug location count does not match opcodes in function ${fn.functionIndex}';
			if (!stableIdsBySlot.exists(fn.functionIndex))
				throw 'Missing stable function identity for slot "${fn.functionIndex}"';
			writeIndex(out, stableIdsBySlot.get(fn.functionIndex));
			writeIndex(out, fn.debugLocations.length);
			for (location in fn.debugLocations) {
				if (!fileIndices.exists(location.path))
					throw 'Missing patch debug source index for "${location.path}"';
				writeIndex(out, fileIndices.get(location.path));
				writeIndex(out, location.line);
				writeIndex(out, location.column);
				writeIndex(out, location.endLine);
				writeIndex(out, location.endColumn);
				out.writeInt32(location.sourceHash);
				writeIndex(out, location.start == null ? 0 : location.start + 1);
				writeIndex(out, location.end == null ? 0 : location.end + 1);
				writeIndex(out, location.flags);
			}
		}
		return out.getBytes();
	}

	static function writeSection(out:BytesOutput, tag:Int, bytes:HaxeBytes):Void {
		out.writeByte(tag);
		writeIndex(out, bytes.length);
		out.write(bytes);
	}

	static function callRelocations(fn:HlFunction, stableIdsBySlot:Map<Int, Int>):Array<{instruction:Int, stableId:Int}> {
		var result = [], instruction = 0;
		for (op in fn.opcodes)
			switch op {
				case Label(_):
					instruction++;
				case Call0(_, target), Call1(_, target, _), Call2(_, target, _, _), Call3(_, target, _, _, _), Call4(_, target, _, _, _, _),
					CallN(_, target, _), StaticClosure(_, target), InstanceClosure(_, target, _):
					if (stableIdsBySlot.exists(target))
						result.push({instruction: instruction, stableId: stableIdsBySlot.get(target)});
					instruction++;
				default:
					instruction++;
			}
		return result;
	}

	static function checkBase(base:Int, total:Int):Void
		if (base < 0 || base > total)
			throw "Invalid HLP symbol base";

	static function writeType(out:BytesOutput, type:HlTypeDef):Void
		switch type {
			case Simple(kind):
				if (kind == HashLinkType.Ref || kind == HashLinkType.Null)
					throw 'HashLink type $kind requires a parameter';
				out.writeByte(kind);
			case Parameterized(kind, parameter):
				if (kind != HashLinkType.Ref && kind != HashLinkType.Null)
					throw 'Unsupported parameterized HashLink patch type $kind';
				out.writeByte(kind);
				writeSignedIndex(out, parameter);
			case Abstract(name):
				out.writeByte(HashLinkType.Abstract);
				writeSignedIndex(out, name);
			case Function(args, result):
				out.writeByte(HashLinkType.Fun);
				out.writeByte(args.length);
				for (a in args)
					writeSignedIndex(out, a);
				writeSignedIndex(out, result);
			case Method(_, _):
				throw "Method type patches require a structural reload";
			case Object(_, _, _, _, _, _):
				throw "Object type patches require a structural reload";
			case Structure(_, _, _, _, _):
				throw "Structure type patches require a structural reload";
			case Virtual(_):
				throw "Virtual type patches require a structural reload";
			case Enum(_, _, _):
				throw "Enum type patches require a structural reload";
		}

	static function writeIndex(out:BytesOutput, v:Int):Void {
		if (v < 0)
			throw 'Negative patch index $v';
		writeSignedIndex(out, v);
	}

	static function writeSignedIndex(out:BytesOutput, v:Int):Void
		out.write(HlWriter.encodeIndex(v));
}
