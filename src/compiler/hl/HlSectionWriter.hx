package compiler.hl;

import compiler.core.InternalError;
import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.HlFunction.HlInstruction;
import compiler.hl.HlWriter.HlSectionIndices;
import compiler.hl.incremental.HlSymbolTable;
import compiler.ir.pipeline.StaticInitializationOrder;
import haxe.io.Bytes;
import haxeon.io.ByteSink;
import haxeon.io.SegmentedBytes;

/** An HLB 9 module (`HlSectionWriter.write`) and the function indices the loader gives it. */
typedef HlSectionOutput = {
	final bytes:SegmentedBytes;

	/**
	 * By function index in the dense module, the index the loader's link gives the function or native: functions in section and
	 * declaration order, then natives in order of first declaration. -1 for a native no section declares, as nothing calls it.
	 */
	final linkedIndices:Array<Int>;
}

/**
 * Writes a dense module (`HlCode`) as HLB 9: one section per module with module-local tables, which names what it uses from
 * other sections by key, and which the VM links when it loads the file (docs/design/MODULE_SECTIONS.md, section 1).
 *
 * Every entry has a home section, the module whose declaration it comes from, or the shared section:
 * - A function's home is the module of the file its code mostly comes from (the anchor most of its positions count from), so
 *   a lambda, a specialization or a dispatcher goes with the declaration it serves. A function with no position from a module
 *   file (printers, runtime helpers, the boot functions) goes to the shared section.
 * - An object type with methods goes with its first method; an enum tag with its enum; any other class, enum or interface
 *   with the first function, in module order, whose registers hold it, else to the shared section. String, the runtime
 *   headers and the anonymous structures are shared definitions, which every section that uses them defines.
 * - A class value or enum constant global goes with its type; another global with the first function that reads or writes
 *   it. A literal constant is no one's: each section has the ones it uses.
 *
 * A section names its function by its name, its types and globals by their symbol names, so a section's bytes depend only on
 * what it owns and on the keys of what it uses.
 */
class HlSectionWriter {
	public static inline final VERSION = 9;

	/** The section that holds what no module owns. Not a module path, so no module's section can take it. */
	public static inline final SHARED_SECTION = "$shared";

	static inline final FILE_DEBUG = 1;
	static inline final SECTION_CODE = 1;
	static inline final SECTION_CODE_VERSION = 1;
	static inline final SECTION_LZ4 = 1;
	static inline final ROLE_STRUCTURAL = 0;
	static inline final ROLE_OWNED = 1;
	static inline final ROLE_SHARED = 2;

	/** `typeHomes` of a type no section owns: a structural type, or a shared definition. */
	static inline final STRUCTURAL = -1;

	static inline final SHARED_DEFINITION = -2;

	/** `globalHomes` of a literal constant. */
	static inline final CONSTANT = -1;

	/**
	 * Writes `code` as HLB 9. `modules` gives the module of each source file by its path (`SourceFile.path`); text in no module
	 * file belongs to the shared section. `compression` is the LZ4 level of the sections (HlLz4), or null to store them as they
	 * are; without the HashLink natives they are stored as they are. `checkReuse` links the result as the loader does
	 * (`HlStaticLink`).
	 */
	public static function write(code:HlCode, modules:Map<String, String>, ?compression:Int,
			checkReuse:Bool = false):HlSectionOutput {
		HlValidator.validate(code, null, checkReuse);
		var writer = new HlSectionWriter(code, modules, compression);
		var output = writer.encode();
		if (checkReuse)
			HlStaticLink.link(output.bytes.flatten());
		return output;
	}

	final code:HlCode;
	final modules:Map<String, String>;
	final compression:Null<Int>;
	final hasDebug:Bool;
	final spans:Bool;

	/** Section paths in file order; the shared section, when it holds anything, last. */
	var paths:Array<String> = [];

	/** By position in `code.functions`, its section. */
	var functionHomes:Array<Int> = [];

	/** By type index: its section, `STRUCTURAL` or `SHARED_DEFINITION`. */
	var typeHomes:Array<Int> = [];

	/** By global index: its section or `CONSTANT`. */
	var globalHomes:Array<Int> = [];

	/** By function index: the position in `code.functions`, or -1 for a native. */
	final functionPositions:Array<Int> = [];

	/** By function index: the position in `code.natives`, or -1 for a function. */
	final nativePositions:Array<Int> = [];

	/** By global index: its constant in `code.constants`, or -1. */
	final constantOfGlobal:Array<Int> = [];

	/** By global index: the type whose class value it holds, or -1. */
	final valueOfGlobal:Array<Int> = [];

	/** By source hash, the section that carries the snapshot. */
	final snapshotHomes:Map<Int, Int> = [];

	// The section being written: what it names, by index in the dense tables, with a stamp per table (`epoch`).
	var epoch = 0;
	var section = 0;
	final intStamps:Array<Int> = [];
	final floatStamps:Array<Int> = [];
	final stringStamps:Array<Int> = [];
	final typeStamps:Array<Int> = [];
	final globalStamps:Array<Int> = [];
	final functionStamps:Array<Int> = [];

	/** By function index of a native: its position in the section's natives. */
	final nativeSlots:Array<Int> = [];
	final local = new HlSectionIndices();
	var tables:HlSectionTables = new HlSectionTables();

	function new(code:HlCode, modules:Map<String, String>, compression:Null<Int>) {
		this.code = code;
		this.modules = modules;
		this.compression = compression;
		var debug = false;
		for (fn in code.functions)
			if (fn.debugLocations.length > 0)
				debug = true;
		hasDebug = debug;
		var withSpans = false;
		for (section in code.debugSections)
			if (section.kind == HlWriter.OPCODE_SOURCE_SPANS)
				withSpans = true;
		spans = withSpans;
		if (code.functionNames.length != code.functions.length)
			throw new InternalError("A module of sections needs the name of every function");
		for (position in 0...code.functions.length)
			setAt(functionPositions, code.functions[position].functionIndex, position);
		for (position in 0...code.natives.length)
			setAt(nativePositions, code.natives[position].functionIndex, position);
		for (index in 0...code.globals.length)
			constantOfGlobal.push(-1);
		for (index in 0...code.constants.length)
			constantOfGlobal[code.constants[index].global] = index;
		fill(valueOfGlobal, code.globals.length);
		for (index in 0...code.types.length)
			switch code.types[index] {
				case Object(_, _, global, _, _, _) | Structure(_, global, _, _, _) if (global > 0):
					valueOfGlobal[global - 1] = index;
				default:
			}
		fill(intStamps, code.ints.length);
		fill(floatStamps, code.floats.length);
		fill(stringStamps, code.strings.length);
		fill(typeStamps, code.types.length);
		fill(globalStamps, code.globals.length);
		fill(functionStamps, functionPositions.length);
		fill(nativeSlots, functionPositions.length);
		fill(local.ints, code.ints.length);
		fill(local.floats, code.floats.length);
		fill(local.strings, code.strings.length);
		fill(local.types, code.types.length);
		fill(local.globals, code.globals.length);
		fill(local.functions, functionPositions.length);
	}

	static function fill(values:Array<Int>, length:Int):Void {
		values.resize(length);
		for (index in 0...length)
			values[index] = -1;
	}

	static function setAt(values:Array<Int>, index:Int, value:Int):Void {
		while (values.length <= index)
			values.push(-1);
		values[index] = value;
	}

	// ---- homes

	/** The module of the source file at `path`, or null for text no module file holds (generated code). */
	inline function modulePath(path:String):Null<String>
		return modules.get(path);

	function assignHomes():Void {
		var sources = code.sources, moduleOf:Array<Null<String>> = [], named:Map<String, Bool> = [];
		var anchors:Array<Int> = [], counts:Array<Int> = [];
		for (fn in code.functions) {
			anchors.resize(0);
			counts.resize(0);
			var last = -1, at = -1;
			for (location in fn.debugLocations) {
				if (location.anchor != last) {
					last = location.anchor;
					at = anchors.indexOf(last);
					if (at < 0) {
						at = anchors.length;
						anchors.push(last);
						counts.push(0);
					}
				}
				counts[at]++;
			}
			var best = -1;
			for (index in 0...anchors.length)
				if (best < 0 || counts[index] > counts[best])
					best = index;
			var module = best < 0 ? null : modulePath(sources.path(anchors[best]));
			moduleOf.push(module);
			if (module != null)
				named.set(module, true);
		}
		var modules = [for (module in named.keys()) module];
		modules.sort(StaticInitializationOrder.compareModules);
		var ids:Map<String, Int> = [];
		for (index in 0...modules.length)
			ids.set(modules[index], index);
		var shared = modules.length;
		paths = modules.concat([SHARED_SECTION]);
		functionHomes = [for (module in moduleOf) module == null ? shared : ids.get(module)];

		// Types: by their methods, their enum, or the first function whose registers hold them.
		var types = code.types,
			firstUse:Array<Int> = [for (_ in 0...types.length) -1],
			globalUse:Array<Int> = [for (_ in 0...code.globals.length) -1];
		for (position in 0...code.functions.length) {
			var fn = code.functions[position], home = functionHomes[position];
			for (register in fn.registers)
				if (firstUse[register] < 0)
					firstUse[register] = home;
			for (instruction in fn.opcodes)
				switch instruction {
					case LoadType(_, type):
						if (firstUse[type] < 0)
							firstUse[type] = home;
					case GlobalGet(_, global) | GlobalSet(global, _):
						if (globalUse[global] < 0)
							globalUse[global] = home;
					default:
				}
		}
		typeHomes = [for (_ in 0...types.length) STRUCTURAL];
		for (index in 0...types.length)
			typeHomes[index] = switch types[index] {
				case Object(name, _, _, _, methods, _) | Structure(name, _, _, methods, _):
					if (HlSymbolTable.isSharedDefinition(code.strings[name])) SHARED_DEFINITION;
					else if (methods.length > 0)
						methodHome(methods[0].functionIndex, shared);
					else firstUse[index] >= 0 ? firstUse[index] : shared;
				case Enum(_, _, _) | Virtual(_, _): firstUse[index] >= 0 ? firstUse[index] : shared;
				default: STRUCTURAL;
			};
		for (index in 0...types.length)
			switch types[index] {
				case EnumTag(boxed, _): typeHomes[index] = typeHomes[boxed] >= 0 ? typeHomes[boxed] : shared;
				default:
			}

		// Globals: a type's value or enum constants go with it; a literal constant is no one's.
		globalHomes = [for (global in 0...code.globals.length) constantOfGlobal[global] >= 0 ? CONSTANT : -2];
		function owner(global:Int, type:Int):Void {
			if (global >= 0 && globalHomes[global] == -2)
				globalHomes[global] = typeHomes[type] >= 0 ? typeHomes[type] : shared;
		}
		for (index in 0...types.length)
			switch types[index] {
				case Object(_, _, global, _, _, _) | Structure(_, global, _, _, _) | Enum(_, global, _):
					owner(global - 1, index);
				case EnumTag(_, cacheGlobals):
					for (global in cacheGlobals)
						owner(global, index);
				default:
			}
		for (global in 0...globalHomes.length)
			if (globalHomes[global] == -2)
				globalHomes[global] = globalUse[global] >= 0 ? globalUse[global] : shared;

		if (spans)
			placeSnapshots(ids, shared);
		dropEmptySections();
	}

	function methodHome(functionIndex:Int, shared:Int):Int {
		var position = functionIndex < functionPositions.length ? functionPositions[functionIndex] : -1;
		return position < 0 ? shared : functionHomes[position];
	}

	/** A source snapshot goes with its file's module when that has a section, else with the first section whose code shows it. */
	function placeSnapshots(ids:Map<String, Int>, shared:Int):Void {
		var sources = code.sources;
		for (position in 0...code.functions.length) {
			var last = -1;
			for (location in code.functions[position].debugLocations)
				if (location.anchor != last && !location.generatedText) {
					last = location.anchor;
					var hash = sources.hash(last);
					if (hash == 0 || snapshotHomes.exists(hash))
						continue;
					var module = modulePath(sources.path(last)), home = module == null ? null : ids.get(module);
					snapshotHomes.set(hash, home ?? functionHomes[position]);
				}
		}
	}

	/** Keeps the sections that own anything, renumbered in file order. */
	function dropEmptySections():Void {
		var used = [for (_ in paths) false];
		for (home in functionHomes)
			used[home] = true;
		for (home in typeHomes)
			if (home >= 0)
				used[home] = true;
		for (home in globalHomes)
			if (home >= 0)
				used[home] = true;
		for (home in snapshotHomes)
			used[home] = true;
		var renumbered = [], kept = [];
		for (index in 0...paths.length) {
			renumbered.push(used[index] ? kept.length : -1);
			if (used[index])
				kept.push(paths[index]);
		}
		paths = kept;
		functionHomes = [for (home in functionHomes) renumbered[home]];
		typeHomes = [for (home in typeHomes) home >= 0 ? renumbered[home] : home];
		globalHomes = [for (home in globalHomes) home >= 0 ? renumbered[home] : home];
		for (hash => home in snapshotHomes)
			snapshotHomes.set(hash, renumbered[home]);
	}

	// ---- keys

	function functionKey(position:Int):String
		return code.functionNames[position];

	function typeKey(index:Int):String
		return switch code.types[index] {
			case Object(name, _, _, _, _, _) | Structure(name, _, _, _, _) | Enum(name, _, _) | Virtual(name, _):
				code.strings[name];
			case EnumTag(boxed, _): "enum-tag:" + typeKey(boxed);
			default: throw new InternalError('HashLink type $index has no key');
		};

	function globalKey(global:Int):String {
		var name = global < code.globalNames.length ? code.globalNames[global] : null;
		if (name != null)
			return name;
		if (valueOfGlobal[global] < 0)
			throw new InternalError('HashLink global $global has no key');
		return "$class:" + typeKey(valueOfGlobal[global]);
	}

	static function kindOf(type:HlTypeDef):Int
		return switch type {
			case Simple(kind) | Parameterized(kind, _): kind;
			case Abstract(_): HlType.Abstract;
			case Function(_, _): HlType.Fun;
			case Method(_, _): HlType.Method;
			case Object(_, _, _, _, _, _): HlType.Obj;
			case Structure(_, _, _, _, _): HlType.Struct;
			case Virtual(_, _): HlType.Virtual;
			case Enum(_, _, _): HlType.Enum;
			case EnumTag(_, _): HlType.EnumTag;
		};

	// ---- what a section names

	function useInt(index:Int):Void
		if (intStamps[index] != epoch) {
			intStamps[index] = epoch;
			local.ints[index] = tables.ints.length;
			tables.ints.push(index);
		}

	function useFloat(index:Int):Void
		if (floatStamps[index] != epoch) {
			floatStamps[index] = epoch;
			local.floats[index] = tables.floats.length;
			tables.floats.push(index);
		}

	function useString(index:Int):Void
		if (stringStamps[index] != epoch) {
			stringStamps[index] = epoch;
			local.strings[index] = tables.strings.length;
			tables.strings.push(index);
		}

	/** A structural type comes after the structural types it is made of; a nominal one is defined here, shared or imported. */
	function useType(index:Int):Void {
		if (typeStamps[index] == epoch)
			return;
		var home = typeHomes[index];
		if (home == STRUCTURAL) {
			switch code.types[index] {
				case Parameterized(_, parameter):
					useType(parameter);
				case Abstract(name):
					useString(name);
				case Function(arguments, result) | Method(arguments, result):
					for (argument in arguments)
						useType(argument);
					useType(result);
				default:
			}
			typeStamps[index] = epoch;
			tables.types.push(index);
			return;
		}
		typeStamps[index] = epoch;
		if (home == section || home == SHARED_DEFINITION) {
			tables.types.push(index);
			tables.definitions.push(index);
		} else
			tables.typeImports.push(index);
	}

	function useGlobal(index:Int):Void {
		if (globalStamps[index] == epoch)
			return;
		var constant = constantOfGlobal[index];
		if (constant >= 0) {
			useConstant(constant);
			globalStamps[index] = epoch;
			tables.constants.push(constant);
			return;
		}
		globalStamps[index] = epoch;
		useType(code.globals[index]);
		if (globalHomes[index] == section)
			tables.globals.push(index);
		else
			tables.globalImports.push(index);
	}

	/** What a constant's fields name, by the kind of each field: it refers only to the constants before it. */
	function useConstant(constant:Int):Void {
		var entry = code.constants[constant], fields = constantFields(code.globals[entry.global]);
		useType(code.globals[entry.global]);
		for (index in 0...entry.fields.length) {
			var value = entry.fields[index];
			switch fieldKind(fields[index].type) {
				case HlType.I32: useInt(value);
				case HlType.Bool:
				case HlType.F64: useFloat(value);
				case HlType.Bytes: useString(value);
				case HlType.Type: useType(value);
				default: useGlobal(value);
			}
		}
	}

	function constantFields(type:Int):Array<compiler.hl.HlCode.HlObjectField>
		return switch code.types[type] {
			case Object(_, _, _, fields, _, _) | Structure(_, _, fields, _, _): fields;
			default: throw new InternalError('A HashLink constant of type $type is not an object');
		};

	function fieldKind(type:Int):Int
		return kindOf(code.types[type]);

	function useFunction(functionIndex:Int):Void {
		if (functionStamps[functionIndex] == epoch)
			return;
		functionStamps[functionIndex] = epoch;
		var position = functionPositions[functionIndex];
		if (position < 0) {
			var native = code.natives[nativePositions[functionIndex]],
				key = code.strings[native.library] + "\n" + code.strings[native.name],
				known = tables.nativeKeys.get(key);
			if (known == null) {
				known = tables.natives.length;
				tables.nativeKeys.set(key, known);
				tables.natives.push(nativePositions[functionIndex]);
				useType(native.type);
			}
			nativeSlots[functionIndex] = known;
			return;
		}
		useType(code.functions[position].type);
		tables.functionImports.push(position);
	}

	function useInstruction(instruction:HlInstruction):Void
		switch instruction {
			case LoadInt(_, constant):
				useInt(constant);
			case LoadFloat(_, constant):
				useFloat(constant);
			case LoadString(_, constant):
				useString(constant);
			case LoadType(_, type):
				useType(type);
			case GlobalGet(_, global) | GlobalSet(global, _):
				useGlobal(global);
			case Call0(_, functionIndex) | Call1(_, functionIndex, _) | Call2(_, functionIndex, _, _) | CallN(_,
				functionIndex, _) | StaticClosure(_, functionIndex) | InstanceClosure(_, functionIndex, _):
				useFunction(functionIndex);
			default:
		}

	/** What a type this section defines names. */
	function useDefinition(index:Int):Void
		switch code.types[index] {
			case Object(name, base, global, fields, methods, bindings):
				if (base >= 0)
					useType(base);
				useObject(name, global, fields, methods, bindings);
			case Structure(name, global, fields, methods, bindings):
				useObject(name, global, fields, methods, bindings);
			case Virtual(name, fields):
				useString(name);
				for (field in fields) {
					useString(field.name);
					useType(field.type);
				}
			case Enum(name, global, constructors):
				useString(name);
				if (global > 0)
					useGlobal(global - 1);
				for (constructor in constructors) {
					useString(constructor.name);
					for (param in constructor.params)
						useType(param);
				}
			case EnumTag(boxed, cacheGlobals):
				useType(boxed);
				for (global in cacheGlobals)
					useGlobal(global);
			default:
		}

	function useObject(name:Int, global:Int, fields:Array<compiler.hl.HlCode.HlObjectField>,
			methods:Array<compiler.hl.HlCode.HlObjectMethod>, bindings:Array<Int>):Void {
		useString(name);
		if (global > 0)
			useGlobal(global - 1);
		for (field in fields) {
			useString(field.name);
			useType(field.type);
		}
		for (method in methods) {
			useString(method.name);
			useFunction(method.functionIndex);
		}
		var at = 1;
		while (at < bindings.length) {
			useFunction(bindings[at]);
			at += 2;
		}
	}

	/** Everything section `id` names, in order of first use: its functions in declaration order, its globals, then its types. */
	function collect(id:Int, owned:Array<Int>, ownedGlobals:Array<Int>, ownedTypes:Array<Int>):Void {
		section = id;
		epoch++;
		tables = new HlSectionTables();
		for (position in owned) {
			functionStamps[code.functions[position].functionIndex] = epoch;
			tables.functions.push(position);
		}
		for (global in ownedGlobals) {
			globalStamps[global] = epoch;
			tables.globals.push(global);
		}
		for (type in ownedTypes)
			useType(type);
		for (global in ownedGlobals)
			useType(code.globals[global]);
		var sources = code.sources;
		for (position in owned) {
			var fn = code.functions[position];
			useType(fn.type);
			for (register in fn.registers)
				useType(register);
			for (instruction in fn.opcodes)
				useInstruction(instruction);
			if (hasDebug) {
				if (fn.debugLocations.length == 0)
					tables.file("<generated>");
				var last = -1;
				for (location in fn.debugLocations)
					if (location.anchor != last) {
						last = location.anchor;
						tables.file(sources.path(last));
					}
				for (assignment in fn.debugAssignments)
					useString(assignment.name);
			}
		}
		var next = 0;
		while (next < tables.definitions.length)
			useDefinition(tables.definitions[next++]);
	}

	// ---- encoding

	function encode():HlSectionOutput {
		assignHomes();
		var ownedFunctions = [for (_ in paths)[]],
			ownedGlobals = [for (_ in paths)[]],
			ownedTypes = [for (_ in paths)[]];
		for (position in 0...functionHomes.length)
			ownedFunctions[functionHomes[position]].push(position);
		for (global in 0...globalHomes.length)
			if (globalHomes[global] >= 0)
				ownedGlobals[globalHomes[global]].push(global);
		for (type in 0...typeHomes.length)
			if (typeHomes[type] >= 0)
				ownedTypes[typeHomes[type]].push(type);
		var snapshots:Array<Array<compiler.hl.HlCode.HlSourceSnapshot>> = [for (_ in paths)[]];
		for (snapshot in code.sourceSnapshots) {
			var home = snapshotHomes.get(snapshot.sourceHash);
			if (home != null)
				snapshots[home].push(snapshot);
		}
		var stored:Array<Bytes> = [],
			linked = [for (_ in 0...functionPositions.length) -1],
			linkedNatives:Map<String, Int> = [],
			natives:Array<Int> = [],
			nextFunction = 0;
		for (id in 0...paths.length) {
			collect(id, ownedFunctions[id], ownedGlobals[id], ownedTypes[id]);
			for (position in tables.functions)
				linked[code.functions[position].functionIndex] = nextFunction++;
			for (position in tables.natives) {
				var native = code.natives[position],
					key = code.strings[native.library] + "\n" + code.strings[native.name];
				if (!linkedNatives.exists(key)) {
					linkedNatives.set(key, natives.length);
					natives.push(position);
				}
			}
			stored.push(sectionBytes(snapshots[id]));
		}
		for (position in 0...code.natives.length) {
			var native = code.natives[position],
				slot = linkedNatives.get(code.strings[native.library] + "\n" + code.strings[native.name]);
			if (slot != null)
				linked[native.functionIndex] = nextFunction + slot;
		}
		var entry = functionPositions[code.entryPoint];
		if (entry < 0)
			throw new InternalError("The entry of a module of sections is a native");
		var head = new HlWriter();
		head.output.writeString("HLB");
		head.output.writeByte(VERSION);
		head.writeUnsignedIndex(hasDebug ? FILE_DEBUG : 0);
		head.writeUnsignedIndex(paths.length);
		var offset = 0;
		for (id in 0...paths.length) {
			head.writeSizedString(paths[id]);
			head.output.writeInt32(offset);
			head.output.writeInt32(stored[id].length);
			digest(head.output, stored[id]);
			offset += stored[id].length;
		}
		head.writeSizedString(paths[functionHomes[entry]]);
		head.writeSizedString(functionKey(entry));
		for (bytes in stored)
			head.writeShared(bytes);
		return {bytes: head.output.finish(), linkedIndices: linked};
	}

	/** The section's reuse key: two 32-bit FNV-1a hashes of its bytes, with different bases. */
	static function digest(output:ByteSink, bytes:Bytes):Void {
		var low = 0x811C9DC5, high = 0x01000193 ^ bytes.length;
		for (index in 0...bytes.length) {
			var byte = bytes.get(index);
			low = (low ^ byte) * 0x01000193;
			high = (high ^ byte) * 0x01000197;
		}
		output.writeInt32(low);
		output.writeInt32(high);
	}

	/** The section's index of each entry it names: in every index space the imports come first. */
	function settleIndices():Void {
		var typeImports = tables.typeImports.length;
		for (position in 0...tables.typeImports.length)
			local.types[tables.typeImports[position]] = position;
		for (position in 0...tables.types.length)
			local.types[tables.types[position]] = typeImports + position;
		var globalImports = tables.globalImports.length, owned = tables.globals.length;
		for (position in 0...tables.globalImports.length)
			local.globals[tables.globalImports[position]] = position;
		for (position in 0...tables.globals.length)
			local.globals[tables.globals[position]] = globalImports + position;
		for (position in 0...tables.constants.length)
			local.globals[code.constants[tables.constants[position]].global] = globalImports + owned + position;
		var functionImports = tables.functionImports.length, natives = tables.natives.length;
		for (position in 0...tables.functionImports.length)
			local.functions[code.functions[tables.functionImports[position]].functionIndex] = position;
		for (position in 0...tables.functions.length)
			local.functions[code.functions[tables.functions[position]].functionIndex] = functionImports + natives
				+ position;
		for (position in 0...code.natives.length) {
			var native = code.natives[position];
			if (functionStamps[native.functionIndex] == epoch)
				local.functions[native.functionIndex] = functionImports + nativeSlots[native.functionIndex];
		}
	}

	function sectionBytes(snapshots:Array<compiler.hl.HlCode.HlSourceSnapshot>):Bytes {
		settleIndices();
		var t = tables, w = new HlWriter(), out = w.output, path = paths[section];
		w.hasDebug = hasDebug;
		w.sources = code.sources;
		w.debugFileIndices = t.fileIndices;
		w.local = local;
		// The names are known once the heads are: the heads are written aside first, then the counts and the pool before them.
		var heads = new HlWriter();
		for (position in t.functionImports) {
			heads.writeUnsignedIndex(t.name(paths[functionHomes[position]]));
			heads.writeUnsignedIndex(t.name(functionKey(position)));
			heads.writeUnsignedIndex(local.types[code.functions[position].type]);
		}
		for (global in t.globalImports) {
			heads.writeUnsignedIndex(t.name(paths[globalHomes[global]]));
			heads.writeUnsignedIndex(t.name(globalKey(global)));
			heads.writeUnsignedIndex(local.types[code.globals[global]]);
		}
		for (type in t.typeImports) {
			heads.writeUnsignedIndex(t.name(paths[typeHomes[type]]));
			heads.writeUnsignedIndex(t.name(typeKey(type)));
			heads.output.writeByte(kindOf(code.types[type]));
		}
		for (position in t.natives) {
			var native = code.natives[position];
			heads.writeUnsignedIndex(t.name(code.strings[native.library]));
			heads.writeUnsignedIndex(t.name(code.strings[native.name]));
			heads.writeUnsignedIndex(local.types[native.type]);
		}
		for (type in t.types) {
			var home = typeHomes[type];
			heads.output.writeByte(home == STRUCTURAL ? ROLE_STRUCTURAL : home == SHARED_DEFINITION
				? ROLE_SHARED : ROLE_OWNED);
			heads.output.writeByte(kindOf(code.types[type]));
			if (home != STRUCTURAL)
				heads.writeUnsignedIndex(t.name(typeKey(type)));
		}
		for (global in t.globals) {
			heads.writeUnsignedIndex(t.name(globalKey(global)));
			heads.writeUnsignedIndex(local.types[code.globals[global]]);
		}
		for (position in t.functions) {
			heads.writeUnsignedIndex(t.name(functionKey(position)));
			heads.writeUnsignedIndex(local.types[code.functions[position].type]);
		}
		for (count in [
			t.names.length, t.functionImports.length, t.globalImports.length, t.typeImports.length, t.natives.length,
			t.types.length, t.globals.length, t.functions.length, t.ints.length, t.floats.length, t.strings.length, 0,
			t.constants.length, t.files.length
		])
			w.writeUnsignedIndex(count);
		w.writeStrings(t.names);
		w.writeShared(heads.bytes());
		for (index in t.ints)
			out.writeInt32(code.ints[index]);
		for (index in t.floats)
			out.writeDouble(code.floats[index]);
		w.writeStrings([for (index in t.strings) code.strings[index]]);
		w.writeStrings(t.files);
		for (type in t.types)
			w.writeType(localType(code.types[type]));
		for (constant in t.constants) {
			var entry = code.constants[constant], fields = constantFields(code.globals[entry.global]);
			w.writeIndex(local.types[code.globals[entry.global]]);
			w.writeUnsignedIndex(entry.fields.length);
			for (index in 0...entry.fields.length) {
				var value = entry.fields[index];
				w.writeUnsignedIndex(switch fieldKind(fields[index].type) {
					case HlType.I32: local.ints[value];
					case HlType.Bool: value;
					case HlType.F64: local.floats[value];
					case HlType.Bytes: local.strings[value];
					case HlType.Type: local.types[value];
					default: local.globals[value];
				});
			}
		}
		for (position in t.functions)
			w.writeFunction(code.functions[position]);
		writeDebugSections(w, snapshots);
		var payload = out.finish().flatten();
		var section = new HlWriter();
		section.writeUnsignedIndex(SECTION_CODE);
		section.writeUnsignedIndex(SECTION_CODE_VERSION);
		var block = compression == null ? null : HlLz4.compress(payload, compression);
		if (block == null) {
			section.writeUnsignedIndex(0);
			section.writeShared(payload);
		} else {
			section.writeUnsignedIndex(SECTION_LZ4);
			section.writeUnsignedIndex(payload.length);
			section.writeShared(block);
		}
		if (path == "")
			throw new InternalError("A module section without a path");
		return section.bytes();
	}

	/** The section's opcode source spans, by its function index, and the snapshots it carries. */
	function writeDebugSections(w:HlWriter, snapshots:Array<compiler.hl.HlCode.HlSourceSnapshot>):Void {
		var sections:Array<{kind:Int, version:Int, payload:Bytes}> = [];
		if (spans) {
			var groups:Array<compiler.hl.HlWriter.HlOpcodeSourceSpanGroup> = [];
			for (position in 0...tables.functions.length) {
				var fn = code.functions[tables.functions[position]];
				if (fn.debugLocations.length > 0)
					groups.push({stableId: position, locations: fn.debugLocations, opcodes: fn.opcodes});
			}
			if (groups.length > 0)
				sections.push({
					kind: HlWriter.OPCODE_SOURCE_SPANS,
					version: 2,
					payload: HlWriter.encodeOpcodeSourceSpanGroups(groups, code.sources).flatten()
				});
		}
		if (snapshots.length > 0)
			sections.push({
				kind: HlWriter.SOURCE_SNAPSHOTS,
				version: 1,
				payload: HlWriter.encodeSourceSnapshots(snapshots).flatten()
			});
		w.writeUnsignedIndex(sections.length);
		for (section in sections) {
			w.writeUnsignedIndex(section.kind);
			w.writeUnsignedIndex(section.version);
			w.writeUnsignedIndex(0);
			w.writeUnsignedIndex(section.payload.length);
			w.writeShared(section.payload);
		}
	}

	/** `type` with the section's indices. */
	function localType(type:HlTypeDef):HlTypeDef {
		var types = local.types, strings = local.strings;
		inline function global(value:Int):Int
			return value > 0 ? local.globals[value - 1] + 1 : 0;
		inline function fields(list:Array<compiler.hl.HlCode.HlObjectField>):Array<compiler.hl.HlCode.HlObjectField>
			return [for (field in list) {name: strings[field.name], type: types[field.type]}];
		inline function methods(list:Array<compiler.hl.HlCode.HlObjectMethod>):Array<compiler.hl.HlCode.HlObjectMethod>
			return [for (method in list) {
				name: strings[method.name],
				functionIndex: local.functions[method.functionIndex],
				prototype: method.prototype
			}];
		inline function bindings(list:Array<Int>):Array<Int>
			return [for (index in 0...list.length) index % 2 == 1 ? local.functions[list[index]] : list[index]];
		return switch type {
			case Simple(_): type;
			case EnumTag(boxed, cacheGlobals): EnumTag(types[boxed],
				[for (value in cacheGlobals) local.globals[value]]);
			case Parameterized(kind, parameter): Parameterized(kind, types[parameter]);
			case Abstract(name): Abstract(strings[name]);
			case Function(arguments, result): Function([for (argument in arguments) types[argument]], types[result]);
			case Method(arguments, result): Method([for (argument in arguments) types[argument]], types[result]);
			case Object(name, base, value, list, methodList, bindingList):
				Object(strings[name], base < 0 ? -1 : types[base], global(value), fields(list), methods(methodList),
					bindings(bindingList));
			case Structure(name, value, list, methodList, bindingList):
				Structure(strings[name], global(value), fields(list), methods(methodList), bindings(bindingList));
			case Virtual(name, list): Virtual(strings[name], fields(list));
			case Enum(name, value, constructors): Enum(strings[name], global(value),
				[for (constructor in constructors) {
					name: strings[constructor.name],
					params: [for (param in constructor.params) types[param]]
				}]);
		};
	}
}

/** The tables of the section being written, each by index in the dense module's table, in the section's order. */
private class HlSectionTables {
	public final names:Array<String> = [];
	public final functionImports:Array<Int> = [];
	public final globalImports:Array<Int> = [];
	public final typeImports:Array<Int> = [];

	/** Positions in `HlCode.natives`, one per library and name. */
	public final natives:Array<Int> = [];

	public final nativeKeys:Map<String, Int> = [];
	public final types:Array<Int> = [];

	/** The types the section defines, owned or shared, whose definitions are still to be walked. */
	public final definitions:Array<Int> = [];

	public final globals:Array<Int> = [];

	/** Positions in `HlCode.functions`. */
	public final functions:Array<Int> = [];

	/** Positions in `HlCode.constants`. */
	public final constants:Array<Int> = [];

	public final ints:Array<Int> = [];
	public final floats:Array<Int> = [];
	public final strings:Array<Int> = [];
	public final files:Array<String> = [];
	public final fileIndices:Map<String, Int> = [];

	final nameIndices:Map<String, Int> = [];

	public function new() {}

	public function name(text:String):Int {
		var known = nameIndices.get(text);
		if (known == null) {
			known = names.length;
			names.push(text);
			nameIndices.set(text, known);
		}
		return known;
	}

	public function file(path:String):Void
		if (!fileIndices.exists(path)) {
			fileIndices.set(path, files.length);
			files.push(path);
		}
}
