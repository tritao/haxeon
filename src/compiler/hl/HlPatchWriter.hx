package compiler.hl;

import haxe.io.Bytes;
import haxe.io.BytesOutput;
import compiler.hl.HlCode.HlTypeDef;

class HlPatchWriter {
	public static inline final VERSION = 4;
	static inline final SYMBOLS = 1;
	static inline final FUNCTIONS = 2;

	public static function encode(code:HlCode, moduleId:Bytes, changedSlots:Array<Int>, stableIdsBySlot:Map<Int, Int>, baseRevision:Int, revision:Int,
			baseInts:Int = 0, baseFloats:Int = 0, baseStrings:Int = 0, baseTypes:Int = 0):Bytes {
		if (baseRevision < 0 || revision <= baseRevision)
			throw "Invalid patch revision range";
		var selected:Array<HlFunction> = [];
		if (moduleId.length != 16)
			throw "Module ID must contain 16 bytes";
		for (index in changedSlots) {
			var found = null;
			for (fn in code.functions)
				if (fn.functionIndex == index) {
					found = fn;
					break;
				}
			if (found == null)
				throw 'Patch references missing function $index';
			selected.push(found);
		}
		var symbols = new BytesOutput();
		symbols.bigEndian = false;
		checkBase(baseInts, code.ints.length);
		symbols.writeInt32(hashInts(code.ints, baseInts));
		writeIndex(symbols, baseInts);
		writeIndex(symbols, code.ints.length - baseInts);
		for (i in baseInts...code.ints.length)
			symbols.writeInt32(code.ints[i]);
		checkBase(baseFloats, code.floats.length);
		symbols.writeInt32(hashFloats(code.floats, baseFloats));
		writeIndex(symbols, baseFloats);
		writeIndex(symbols, code.floats.length - baseFloats);
		for (i in baseFloats...code.floats.length)
			symbols.writeDouble(code.floats[i]);
		checkBase(baseStrings, code.strings.length);
		symbols.writeInt32(hashStrings(code.strings, baseStrings));
		writeIndex(symbols, baseStrings);
		writeIndex(symbols, code.strings.length - baseStrings);
		for (i in baseStrings...code.strings.length) {
			var b = Bytes.ofString(code.strings[i]);
			writeIndex(symbols, b.length);
			symbols.write(b);
		}
		checkBase(baseTypes, code.types.length);
		symbols.writeInt32(hashTypes(code.types, baseTypes));
		writeIndex(symbols, baseTypes);
		writeIndex(symbols, code.types.length - baseTypes);
		for (i in baseTypes...code.types.length)
			writeType(symbols, code.types[i]);
		var functions = new BytesOutput();
		functions.bigEndian = false;
		writeIndex(functions, selected.length);
		for (fn in selected) {
			var stableId = stableIdsBySlot.get(fn.functionIndex);
			if (stableId == null)
				throw 'Missing stable ID for function slot ${fn.functionIndex}';
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
		out.bigEndian = false;
		out.writeString("HLP");
		out.writeByte(VERSION);
		out.write(moduleId);
		writeIndex(out, baseRevision);
		writeIndex(out, revision);
		writeIndex(out, 2);
		writeSection(out, SYMBOLS, symbols.getBytes());
		writeSection(out, FUNCTIONS, functions.getBytes());
		return out.getBytes();
	}

	static function writeSection(out:BytesOutput, tag:Int, bytes:Bytes):Void {
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
				case Call0(_, target), Call1(_, target, _), Call2(_, target, _, _), CallN(_, target, _):
					var stableId = stableIdsBySlot.get(target);
					if (stableId != null)
						result.push({instruction: instruction, stableId: stableId});
					instruction++;
				default:
					instruction++;
			}
		return result;
	}

	static function hashBytes(bytes:Bytes, hash:Int = cast 0x811C9DC5):Int {
		var h = hash;
		for (i in 0...bytes.length)
			h = (h ^ bytes.get(i)) * 16777619;
		return h;
	}

	static function intBytes(value:Int):Bytes {
		var out = new BytesOutput();
		out.bigEndian = false;
		out.writeInt32(value);
		return out.getBytes();
	}

	static function hashInts(values:Array<Int>, count:Int):Int {
		var h:Int = cast 0x811C9DC5;
		for (i in 0...count)
			h = hashBytes(intBytes(values[i]), h);
		return h;
	}

	static function hashFloats(values:Array<Float>, count:Int):Int {
		var h:Int = cast 0x811C9DC5;
		for (i in 0...count) {
			var out = new BytesOutput();
			out.bigEndian = false;
			out.writeDouble(values[i]);
			h = hashBytes(out.getBytes(), h);
		}
		return h;
	}

	static function hashStrings(values:Array<String>, count:Int):Int {
		var h:Int = cast 0x811C9DC5;
		for (i in 0...count) {
			var b = Bytes.ofString(values[i]);
			h = hashBytes(intBytes(b.length), h);
			h = hashBytes(b, h);
		}
		return h;
	}

	static function hashTypes(values:Array<HlTypeDef>, count:Int):Int {
		var h:Int = cast 0x811C9DC5;
		for (i in 0...count)
			switch values[i] {
				case Simple(kind):
					h = hashBytes(intBytes(kind), h);
				case Function(args, result):
					h = hashBytes(intBytes(HlType.Fun), h);
					h = hashBytes(intBytes(args.length), h);
					for (a in args)
						h = hashBytes(intBytes(a), h);
					h = hashBytes(intBytes(result), h);
				case Object(name, base, global, fields, methods, bindings):
					h = hashBytes(intBytes(HlType.Obj), h);
					h = hashBytes(intBytes(name), h);
					h = hashBytes(intBytes(base), h);
					h = hashBytes(intBytes(global), h);
					h = hashBytes(intBytes(fields.length), h);
					for (field in fields) {
						h = hashBytes(intBytes(field.name), h);
						h = hashBytes(intBytes(field.type), h);
					}
					h = hashBytes(intBytes(methods.length), h);
					for (method in methods) {
						h = hashBytes(intBytes(method.name), h);
						h = hashBytes(intBytes(method.functionIndex), h);
						h = hashBytes(intBytes(method.prototype), h);
					}
					h = hashBytes(intBytes(bindings.length), h);
					for (binding in bindings)
						h = hashBytes(intBytes(binding), h);
			}
		return h;
	}

	static function checkBase(base:Int, total:Int):Void
		if (base < 0 || base > total)
			throw "Invalid HLP symbol base";

	static function writeType(out:BytesOutput, type:HlTypeDef):Void
		switch type {
			case Simple(kind):
				out.writeByte(kind);
			case Function(args, result):
				out.writeByte(HlType.Fun);
				out.writeByte(args.length);
				for (a in args)
					writeSignedIndex(out, a);
				writeSignedIndex(out, result);
			case Object(_, _, _, _, _, _):
				throw "Object type patches require a structural reload";
		}

	static function writeIndex(out:BytesOutput, v:Int):Void {
		if (v < 0)
			throw 'Negative patch index $v';
		writeSignedIndex(out, v);
	}

	static function writeSignedIndex(out:BytesOutput, v:Int):Void
		out.write(HlWriter.encodeIndex(v));
}
