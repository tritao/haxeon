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
	static inline final ADDED_FUNCTIONS = 5;
	static inline final GLOBALS = 6;

	/**
	 * `addedFunctions` are the changed slots the running module does not have yet, with their names; they must be the
	 * slots after the module's last, in order. `baseGlobals` is how many globals the running module has: the module's
	 * globals past it, which must all be constants, travel in the patch. Without it the patch adds none.
	 */
	public static function encode(code:HlCode, moduleId:HaxeBytes, changedSlots:Array<Int>, stableIdsBySlot:Map<Int, Int>, baseRevision:Int, revision:Int,
			baseInts:Int = 0, baseFloats:Int = 0, baseStrings:Int = 0, baseTypes:Int = 0, ?extensionSections:Array<{
			tag:Int,
			bytes:HaxeBytes
		}>, ?addedFunctions:Array<{slot:Int, name:String}>,
			baseGlobals:Int = -1):HaxeBytes {
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
			var b = HaxeBytes.ofString(code.strings[i]);
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
			snapshots = encodeSourceSnapshots(code, selected),
			added = addedFunctions == null
				|| addedFunctions.length == 0 ? null : encodeAddedFunctions(selected, addedFunctions, stableIdsBySlot),
			globals = baseGlobals < 0 || baseGlobals == code.globals.length ? null : encodeGlobals(code, baseGlobals);
		out.bigEndian = false;
		out.writeString(HlPatchFormat.MAGIC);
		out.writeByte(HlPatchFormat.VERSION);
		out.write(moduleId);
		writeIndex(out, baseRevision);
		writeIndex(out, revision);
		var extensions = extensionSections == null ? [] : extensionSections;
		for (section in extensions)
			if (section.tag == SYMBOLS || section.tag == FUNCTIONS || section.tag == DEBUG || section.tag == SOURCE_SNAPSHOTS
				|| section.tag == ADDED_FUNCTIONS || section.tag == GLOBALS)
				throw 'Extension section uses reserved HLP tag ${section.tag}';
		writeIndex(out, 2
			+ (debug == null ? 0 : 1)
			+ (snapshots == null ? 0 : 1)
			+ (added == null ? 0 : 1)
			+ (globals == null ? 0 : 1)
			+ extensions.length);
		writeSection(out, SYMBOLS, symbols.getBytes());
		writeSection(out, FUNCTIONS, functions.getBytes());
		if (debug != null)
			writeSection(out, DEBUG, debug);
		if (snapshots != null)
			writeSection(out, SOURCE_SNAPSHOTS, snapshots);
		if (added != null)
			writeSection(out, ADDED_FUNCTIONS, added);
		if (globals != null)
			writeSection(out, GLOBALS, globals);
		for (section in extensions)
			writeSection(out, section.tag, section.bytes);
		return out.getBytes();
	}

	/**
	 * The globals the running module lacks, each a kind byte and its type. A String constant (kind 1) then has the fields its
	 * object is made of, as indices into the module's ints and strings. The value slot of a new object type (kind 0) starts
	 * null. A patch cannot add any other global.
	 */
	static function encodeGlobals(code:HlCode, baseGlobals:Int):HaxeBytes {
		checkBase(baseGlobals, code.globals.length);
		// Constants follow the order of their globals, so the new ones are a suffix found by bisection.
		var low = 0, high = code.constants.length;
		while (low < high) {
			var middle = (low + high) >> 1;
			if (code.constants[middle].global < baseGlobals)
				low = middle + 1;
			else
				high = middle;
		}
		var count = code.globals.length - baseGlobals, next = low;
		var out = new BytesOutput();
		out.bigEndian = false;
		out.writeInt32(hashGlobals(code.globals, baseGlobals));
		writeIndex(out, baseGlobals);
		writeIndex(out, count);
		for (global in baseGlobals...code.globals.length) {
			if (next < code.constants.length && code.constants[next].global == global) {
				var constant = code.constants[next++];
				out.writeByte(1);
				writeIndex(out, code.globals[global]);
				writeIndex(out, constant.fields.length);
				for (field in constant.fields)
					writeIndex(out, field);
			} else if (isObjectValueGlobal(code, global)) {
				out.writeByte(0);
				writeIndex(out, code.globals[global]);
			} else
				throw "A patch can add only constant globals and the value globals of new object types";
		}
		return out.getBytes();
	}

	/** Whether `global` is the value slot of the object or struct type it holds (`HlSymbolTable.internObject`). */
	public static function isObjectValueGlobal(code:HlCode, global:Int):Bool
		return switch code.types[code.globals[global]] {
			case Object(_, _, value, _, _, _), Structure(_, value, _, _, _): value == global + 1;
			default: false;
		};

	static function encodeAddedFunctions(selected:Array<HlFunction>, added:Array<{slot:Int, name:String}>, stableIdsBySlot:Map<Int, Int>):HaxeBytes {
		var out = new BytesOutput();
		out.bigEndian = false;
		writeIndex(out, added.length);
		for (entry in added) {
			var found:Null<HlFunction> = null;
			for (fn in selected)
				if (fn.functionIndex == entry.slot)
					found = fn;
			if (found == null)
				throw 'Added function slot ${entry.slot} has no body in the patch';
			if (!stableIdsBySlot.exists(entry.slot))
				throw 'Missing stable ID for added function slot ${entry.slot}';
			var name = HaxeBytes.ofString(entry.name);
			writeIndex(out, stableIdsBySlot.get(entry.slot));
			writeIndex(out, entry.slot);
			writeSignedIndex(out, found.type);
			writeIndex(out, name.length);
			out.write(name);
		}
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
				case Call0(_, target), Call1(_, target, _), Call2(_, target, _, _), CallN(_, target, _), StaticClosure(_, target),
					InstanceClosure(_, target, _):
					if (stableIdsBySlot.exists(target))
						result.push({instruction: instruction, stableId: stableIdsBySlot.get(target)});
					instruction++;
				default:
					instruction++;
			}
		return result;
	}

	static function hashBytes(bytes:HaxeBytes, hash:Int = cast 0x811C9DC5):Int {
		var h = hash;
		for (i in 0...bytes.length)
			h = (h ^ bytes.get(i)) * 16777619;
		return h;
	}

	/** The type of each global before `count`, hashed without allocating: a module has thousands of literal globals. */
	static function hashGlobals(globals:Array<Int>, count:Int):Int {
		var h:Int = cast 0x811C9DC5;
		for (i in 0...count) {
			var value = globals[i];
			h = (h ^ (value & 255)) * 16777619;
			h = (h ^ ((value >> 8) & 255)) * 16777619;
			h = (h ^ ((value >> 16) & 255)) * 16777619;
			h = (h ^ ((value >>> 24) & 255)) * 16777619;
		}
		return h;
	}

	static function intBytes(value:Int):HaxeBytes {
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
			var b = HaxeBytes.ofString(values[i]);
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
				case Parameterized(kind, parameter):
					h = hashBytes(intBytes(kind), h);
					h = hashBytes(intBytes(parameter), h);
				case Abstract(name):
					h = hashBytes(intBytes(HashLinkType.Abstract), h);
					h = hashBytes(intBytes(name), h);
				case Function(args, result):
					h = hashBytes(intBytes(HashLinkType.Fun), h);
					h = hashBytes(intBytes(args.length), h);
					for (a in args)
						h = hashBytes(intBytes(a), h);
					h = hashBytes(intBytes(result), h);
				case Object(name, base, global, fields, methods, bindings):
					h = hashBytes(intBytes(HashLinkType.Obj), h);
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
				case Structure(name, global, fields, methods, bindings):
					h = hashBytes(intBytes(HashLinkType.Struct), h);
					h = hashBytes(intBytes(name), h);
					h = hashBytes(intBytes(-1), h);
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
				case Virtual(fields):
					h = hashBytes(intBytes(HashLinkType.Virtual), h);
					h = hashBytes(intBytes(fields.length), h);
					for (field in fields) {
						h = hashBytes(intBytes(field.name), h);
						h = hashBytes(intBytes(field.type), h);
					}
				case Enum(name, global, constructors):
					h = hashBytes(intBytes(HashLinkType.Enum), h);
					h = hashBytes(intBytes(name), h);
					h = hashBytes(intBytes(global), h);
					h = hashBytes(intBytes(constructors.length), h);
					for (constructor in constructors) {
						h = hashBytes(intBytes(constructor.name), h);
						h = hashBytes(intBytes(constructor.params.length), h);
						for (param in constructor.params)
							h = hashBytes(intBytes(param), h);
					}
			}
		return h;
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
				if (kind != HashLinkType.Ref && kind != HashLinkType.Null && kind != HashLinkType.Packed)
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
			// As an HLB file has them: name, base, value global, the counts, then fields, methods and bindings.
			case Object(name, base, global, fields, methods, bindings):
				out.writeByte(HashLinkType.Obj);
				writeObjectType(out, name, base, global, fields, methods, bindings);
			case Structure(name, global, fields, methods, bindings):
				out.writeByte(HashLinkType.Struct);
				writeObjectType(out, name, -1, global, fields, methods, bindings);
			case Virtual(fields):
				out.writeByte(HashLinkType.Virtual);
				writeIndex(out, fields.length);
				for (field in fields) {
					writeIndex(out, field.name);
					writeIndex(out, field.type);
				}
			case Enum(_, _, _):
				throw "Enum type patches require a structural reload";
		}

	static function writeObjectType(out:BytesOutput, name:Int, base:Int, global:Int, fields:Array<compiler.hl.HlCode.HlObjectField>,
			methods:Array<compiler.hl.HlCode.HlObjectMethod>, bindings:Array<Int>):Void {
		if (bindings.length % 2 != 0)
			throw "Object bindings come in field and function pairs";
		writeIndex(out, name);
		writeSignedIndex(out, base);
		writeIndex(out, global);
		writeIndex(out, fields.length);
		writeIndex(out, methods.length);
		writeIndex(out, bindings.length >> 1);
		for (field in fields) {
			writeIndex(out, field.name);
			writeIndex(out, field.type);
		}
		for (method in methods) {
			writeIndex(out, method.name);
			writeIndex(out, method.functionIndex);
			writeSignedIndex(out, method.prototype);
		}
		for (binding in bindings)
			writeIndex(out, binding);
	}

	static function writeIndex(out:BytesOutput, v:Int):Void {
		if (v < 0)
			throw 'Negative patch index $v';
		writeSignedIndex(out, v);
	}

	static function writeSignedIndex(out:BytesOutput, v:Int):Void
		out.write(HlWriter.encodeIndex(v));
}
