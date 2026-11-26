package compiler.hl;

import compiler.core.InternalError;
import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.HlFunction.HlInstruction;
import compiler.hl.HlWriter.HlSectionIndices;
import compiler.hl.incremental.HlRelocations;
import compiler.hl.incremental.HlRequestKeys;
import compiler.hl.incremental.HlSymbolRequest.HlRemap;
import compiler.hl.incremental.HlSymbolTable;
import compiler.ir.pipeline.StaticInitializationOrder;
import compiler.semantic.DeclarationOwners;
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

	/** What the next build keeps its sections from. */
	final cache:HlSectionCache;

	/**
	 * How many sections the module has, how many of them this build encoded (it kept the others), and how many of those came
	 * out other than they were.
	 */
	final sections:Int;

	final encoded:Int;
	final changed:Int;
}

/**
 * Writes a dense module (`HlCode`) as HLB 9: one section per module with module-local tables, which names what it uses from
 * other sections by key, and which the VM links when it loads the file (docs/design/MODULE_SECTIONS.md, section 1).
 *
 * Every entry has a home section, the module that declares what it is named after, or the shared section (`declaringModule`):
 * - A function goes with the declaration its name is qualified by: a method, a lambda, a specialization or a dispatcher with
 *   the type or module function it serves. A function named after no declaration (structure printers, runtime helpers, the boot
 *   functions) goes to the shared section.
 * - A class, enum or interface goes with its declaration, an enum tag with its enum. String, the runtime headers and the
 *   anonymous structures are shared definitions, which every section that uses them defines.
 * - A class value or enum constant global goes with its type, a static with its declaration. A literal constant is no one's:
 *   each section has the ones it uses.
 * - A source snapshot goes with the module of its file.
 * So homes depend on declarations alone, never on what code uses what, and an edit changes only the sections whose content it
 * changes.
 *
 * A section names its function by its name, its types and globals by their symbol names, so a section's bytes depend only on
 * what it owns and on the keys of what it uses. A section whose encoding would read the same as last build's is kept as it was
 * (`HlSectionCache`).
 *
 * The module is a sectioned build's (`HlCode.relocations`): each function is the object the build that lowered it made, with
 * that build's indices, and the writer finds what they name in this build's tables. Its section-local tables never depend on
 * how the dense tables are numbered: each is in order of first use, and an entry is its content.
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
	 * The kinds of what a function's code names (`HlLoweredFunction.uses`): the tables of `HlRequestKeys`, then a debug name,
	 * a string only a development build writes.
	 */
	static inline final USE_INT = HlRequestKeys.INTS;

	static inline final USE_FLOAT = HlRequestKeys.FLOATS;
	static inline final USE_STRING = HlRequestKeys.STRINGS;
	static inline final USE_TYPE = HlRequestKeys.TYPES;
	static inline final USE_GLOBAL = HlRequestKeys.GLOBALS;
	static inline final USE_FUNCTION = HlRequestKeys.FUNCTIONS;
	static inline final USE_DEBUG_NAME = HlRequestKeys.FUNCTIONS + 1;

	/**
	 * Writes `code` as HLB 9. `modules` gives the content hash of each module's file by the module's path, and `declarations`
	 * the module that declares each type: together they decide every home. `compression` is the LZ4 level of the sections
	 * (HlLz4), or null to store them as they are; without the HashLink natives they are stored as they are. A section of
	 * `previous` (the last build's) whose encoding would read the same is kept. `checkReuse` encodes the kept sections again to
	 * check they are the same, and links the result as the loader does (`HlStaticLink`). Without `memoize`, for a compile no
	 * later build follows, the sections' reads are not taken and the cache returned keeps none.
	 */
	public static function write(code:HlCode, modules:Map<String, Int>, declarations:DeclarationOwners,
			?compression:Int, checkReuse:Bool = false, ?previous:HlSectionCache, memoize:Bool = true):HlSectionOutput {
		var writer = new HlSectionWriter(code, compression),
			cache = HlSectionCache.following(previous, writer.format(), modules, declarations);
		HlValidator.validate(code, cache.validation, checkReuse);
		cache.validation.retainFunctions(code.functions);
		var output = writer.encode(cache, modules, declarations, checkReuse, memoize);
		if (checkReuse)
			HlStaticLink.link(output.bytes.flatten());
		return output;
	}

	/**
	 * The module that declares what `name` (a function's, type's or global's) is named after, or null for none. A generated
	 * name spells the declaration it serves among its parts: `$lambda:pkg.Type.method:...`, `$generic:pkg.Type.method[...]<...>`,
	 * `$dispatch:pkg.Type.method`, `pkg.Mod$fields.x`; the first part, up to its type arguments, that names a declared type or a
	 * module (its longest dotted prefix that does) decides. A structure printer serves no declaration: printers go together
	 * to the shared section (docs/design/MODULE_SECTIONS.md, section 9).
	 */
	public static function declaringModule(name:String, declarations:DeclarationOwners,
			modules:Map<String, Int>):Null<String> {
		if (StringTools.startsWith(name, STRUCTURE_PRINTER))
			return null;
		var end = 0;
		while (end < name.length && !endsDeclaration(name.charCodeAt(end)))
			end++;
		var start = 0;
		while (start < end) {
			var stop = name.indexOf(":", start);
			if (stop < 0 || stop > end)
				stop = end;
			var from = start;
			while (from < stop && name.charCodeAt(from) == "$".code)
				from++;
			var cut = name.indexOf("$", from);
			var to = cut < 0 || cut > stop ? stop : cut;
			while (to > from) {
				var candidate = name.substring(from, to), module = declarations.get(candidate);
				if (module != null)
					return module;
				if (modules.exists(candidate))
					return candidate;
				to = name.lastIndexOf(".", to - 1);
				if (to < from)
					break;
			}
			start = stop + 1;
		}
		return null;
	}

	static inline final STRUCTURE_PRINTER = "$anon:";

	/** Where the declaration part of a generated name ends: its type arguments, its layout, a lambda's place. */
	static inline function endsDeclaration(code:Int):Bool
		return code == "[".code || code == "<".code || code == "{".code || code == "(".code || code == "#".code
			|| code == "@".code;

	final code:HlCode;
	final relocations:HlRelocations;

	/** Where this build's tables hold what the function being collected names. */
	final remap = new HlRemap();

	/** By index of a function's code, the section's index of what it names: the indices the function is written with. */
	final functionLocal = new HlSectionIndices();

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

	function new(code:HlCode, compression:Null<Int>) {
		this.code = code;
		var relocated = code.relocations;
		if (relocated == null)
			throw new InternalError("A module of sections is written from a sectioned build's lowering");
		relocations = relocated;
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
			setAt(functionPositions, relocations.functionIndices[position], position);
		for (position in 0...code.natives.length)
			setAt(nativePositions, code.natives[position].functionIndex, position);
		while (nativePositions.length < functionPositions.length)
			nativePositions.push(-1);
		while (functionPositions.length < nativePositions.length)
			functionPositions.push(-1);
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

	/** What sections are encoded with besides their content: a section of another format is never kept. */
	function format():String
		return (hasDebug ? "debug" : "plain") + (spans ? "+spans" : "") + ":" + compression;

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

	function assignHomes(cache:HlSectionCache, modules:Map<String, Int>, declarations:DeclarationOwners):Void {
		var ids:Map<String, Int> = [], named:Array<String> = [];
		function sectionOf(name:String):Int {
			var module = cache.homeOf(name, declarations, modules), id = ids.get(module);
			if (id == null) {
				id = named.length;
				ids.set(module, id);
				named.push(module);
			}
			return id;
		}
		function sharedSection():Int {
			var id = ids.get(SHARED_SECTION);
			if (id == null) {
				id = named.length;
				ids.set(SHARED_SECTION, id);
				named.push(SHARED_SECTION);
			}
			return id;
		}
		functionHomes = [for (position in 0...code.functions.length) sectionOf(code.functionNames[position])];
		var types = code.types;
		typeHomes = [for (index in 0...types.length)
			switch types[index] {
				case Object(name, _, _, _, _, _) | Structure(name, _, _, _, _):
					HlSymbolTable.isSharedDefinition(code.strings[name])
						? SHARED_DEFINITION : sectionOf(code.strings[name]);
				case Enum(name, _, _) | Virtual(name, _): sectionOf(code.strings[name]);
				default: STRUCTURAL;
			}];
		for (index in 0...types.length)
			switch types[index] {
				case EnumTag(boxed, _): typeHomes[index] = typeHomes[boxed] >= 0 ? typeHomes[boxed] : sharedSection();
				default:
			}

		// Globals: a type's value or enum constants go with it, a static with its declaration; a literal constant is no one's.
		globalHomes = [for (global in 0...code.globals.length) constantOfGlobal[global] >= 0 ? CONSTANT : -2];
		function owner(global:Int, type:Int):Void {
			if (global >= 0 && globalHomes[global] == -2)
				globalHomes[global] = typeHomes[type] >= 0 ? typeHomes[type] : sharedSection();
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
				globalHomes[global] = sectionOf(globalKey(global));

		// A snapshot is of a module's file (`HashLinkBackendSession.attachSourceSnapshots`).
		if (spans && code.sourceSnapshots.length > 0) {
			var byHash:Map<Int, String> = [];
			for (module => hash in modules)
				if (!byHash.exists(hash) || StaticInitializationOrder.compareModules(module, byHash.get(hash)) < 0)
					byHash.set(hash, module);
			for (snapshot in code.sourceSnapshots) {
				var module = byHash.get(snapshot.sourceHash);
				snapshotHomes.set(snapshot.sourceHash, module == null ? sharedSection() : sectionOf(module));
			}
		}

		// The sections in file order: modules in path order, the shared section last.
		var order = cache.orderOf(named);
		var renumbered = [for (_ in named) -1];
		for (index in 0...order.length)
			renumbered[ids.get(order[index])] = index;
		paths = order;
		functionHomes = [for (home in functionHomes) renumbered[home]];
		typeHomes = [for (home in typeHomes) home >= 0 ? renumbered[home] : home];
		globalHomes = [for (home in globalHomes) home >= 0 ? renumbered[home] : home];
		for (hash => home in snapshotHomes)
			snapshotHomes.set(hash, renumbered[home]);
	}

	// ---- keys

	function functionKey(position:Int):String
		return code.functionNames[position];

	/** The type of the function at `position`, in this build's tables. */
	inline function functionType(position:Int):Int
		return relocations.functionTypes[position];

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

	function hasGlobalKey(global:Int):Bool
		return global < code.globalNames.length && code.globalNames[global] != null || valueOfGlobal[global] >= 0;

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
				tables.nativeOrder.push(key);
				useType(native.type);
			}
			tables.nativeFunctions.push(functionIndex);
			nativeSlots[functionIndex] = known;
			return;
		}
		useType(functionType(position));
		tables.functionImports.push(functionIndex);
	}

	/** What `fn`'s code names, in the order the encoding meets it: its type, its registers', its instructions', its debug names. */
	static function usesOf(fn:HlFunction):Array<Int> {
		var uses = [USE_TYPE, fn.type];
		for (register in fn.registers) {
			uses.push(USE_TYPE);
			uses.push(register);
		}
		for (instruction in fn.opcodes)
			switch instruction {
				case LoadInt(_, constant):
					uses.push(USE_INT);
					uses.push(constant);
				case LoadFloat(_, constant):
					uses.push(USE_FLOAT);
					uses.push(constant);
				case LoadString(_, constant):
					uses.push(USE_STRING);
					uses.push(constant);
				case LoadType(_, type):
					uses.push(USE_TYPE);
					uses.push(type);
				case GlobalGet(_, global) | GlobalSet(global, _):
					uses.push(USE_GLOBAL);
					uses.push(global);
				case Call0(_, functionIndex) | Call1(_, functionIndex, _) | Call2(_, functionIndex, _, _) | CallN(_,
					functionIndex, _) | StaticClosure(_, functionIndex) | InstanceClosure(_, functionIndex, _):
					uses.push(USE_FUNCTION);
					uses.push(functionIndex);
				case New(_, type, _):
					uses.push(USE_TYPE);
					uses.push(type);
				default:
			}
		for (assignment in fn.debugAssignments) {
			uses.push(USE_DEBUG_NAME);
			uses.push(assignment.name);
		}
		return uses;
	}

	/** `usesOf` the function at `position`, made once for the function object. */
	function usesAt(position:Int):Array<Int> {
		var entry = relocations.lowered[position], known = entry.uses;
		if (known == null) {
			known = usesOf(entry.fn);
			entry.uses = known;
		}
		return known;
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

	/**
	 * Everything section `id` names, in order of first use: its functions in declaration order, its globals, then its types. The
	 * section's tables are complete after it, their section indices after `settleIndices`.
	 */
	function collect(id:Int, owned:Array<Int>, ownedGlobals:Array<Int>, ownedTypes:Array<Int>):Void {
		section = id;
		epoch++;
		tables = new HlSectionTables();
		for (position in owned) {
			functionStamps[relocations.functionIndices[position]] = epoch;
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
		var sources = code.sources, found = tables.uses;
		for (position in owned) {
			// A function whose requests have the answers its code names needs no remap.
			var moves = relocations.moves[position];
			if (moves)
				relocations.fill(position, remap);
			var uses = usesAt(position), at = 0;
			tables.useStarts.push(found.length);
			while (at < uses.length) {
				var kind = uses[at],
					index = moves ? remap.get(kind == USE_DEBUG_NAME ? USE_STRING : kind, uses[at + 1]) : uses[at + 1];
				at += 2;
				if (index < 0)
					throw new InternalError('HashLink sections: ${code.functionNames[position]} names an entry its requests did not ask for');
				found.push(index);
				switch kind {
					case USE_INT: useInt(index);
					case USE_FLOAT: useFloat(index);
					case USE_STRING: useString(index);
					case USE_TYPE: useType(index);
					case USE_GLOBAL: useGlobal(index);
					case USE_FUNCTION: useFunction(index);
					default:
				}
			}
			if (hasDebug) {
				var fn = code.functions[position];
				if (fn.debugLocations.length == 0)
					tables.file("<generated>");
				// Its files in order of first use, as its lines name them.
				for (anchor in fn.anchors())
					tables.file(sources.path(anchor));
				// The debug names last, as the encoding writes them.
				at = 0;
				var start = tables.useStarts[tables.useStarts.length - 1];
				while (at < uses.length) {
					if (uses[at] == USE_DEBUG_NAME)
						useString(found[start + (at >> 1)]);
					at += 2;
				}
			}
		}
		var next = 0;
		while (next < tables.definitions.length)
			useDefinition(tables.definitions[next++]);
	}

	/** The section's index of entry `index` of the dense table `kind` names, once `settleIndices` gave them. */
	inline function localIndex(kind:Int, index:Int):Int
		return switch kind {
			case USE_INT: local.ints[index];
			case USE_FLOAT: local.floats[index];
			case USE_TYPE: local.types[index];
			case USE_GLOBAL: local.globals[index];
			case USE_FUNCTION: local.functions[index];
			default: local.strings[index];
		};

	/** Gives `functionLocal` the section's index of everything the function at `functions[index]` of the section names. */
	function localizeFunction(index:Int):Void {
		var t = tables, uses = usesAt(t.functions[index]), start = t.useStarts[index], at = 0, target = functionLocal;
		while (at < uses.length) {
			var kind = uses[at], from = uses[at + 1], to = localIndex(kind, t.uses[start + (at >> 1)]);
			at += 2;
			setAt(switch kind {
				case USE_INT: target.ints;
				case USE_FLOAT: target.floats;
				case USE_TYPE: target.types;
				case USE_GLOBAL: target.globals;
				case USE_FUNCTION: target.functions;
				default: target.strings;
			}, from, to);
		}
	}

	// ---- what a section's encoding reads

	/**
	 * Records into `reads`, or checks against them, what the encoding of the section owning the functions at `owned` reads of
	 * them and of the sources: the functions, their names and the places of the anchors their lines count from, and the
	 * snapshots it carries. Returns whether they still read the same (always, when recording).
	 */
	function readOwn(reads:HlSectionReads, owned:Array<Int>,
			snapshots:Array<compiler.hl.HlCode.HlSourceSnapshot>):Bool {
		var sources = code.sources;
		reads.int(owned.length);
		for (position in owned) {
			var fn = code.functions[position];
			reads.object(fn, spans);
			reads.string(code.functionNames[position]);
			// Lines count from their anchor's line in its file; opcode spans add its offset and its file's hash.
			if (hasDebug)
				for (anchor in fn.anchors()) {
					reads.int(sources.line(anchor));
					reads.string(sources.path(anchor));
					if (spans) {
						reads.int(sources.offset(anchor));
						reads.int(sources.hash(anchor));
					}
				}
			if (!reads.same)
				return false;
		}
		reads.int(snapshots.length);
		for (snapshot in snapshots)
			reads.int(snapshot.sourceHash);
		return reads.same;
	}

	/**
	 * Records into `reads` everything else the encoding of the section `collect` and `settleIndices` just made tables for
	 * reads: the section's index of everything each of its functions names, then each entry of its tables with what it is, its
	 * key and its home where the encoding writes them, in the section's indices. None of these depends on how the dense tables
	 * are numbered; with `readOwn`, whatever reads the same encodes the same.
	 */
	function readNamed(reads:HlSectionReads):Void {
		var t = tables, types = code.types, strings = code.strings, globals = code.globals;
		for (index in 0...t.functions.length) {
			var uses = usesAt(t.functions[index]), start = t.useStarts[index], at = 0;
			while (at < uses.length) {
				reads.int(localIndex(uses[at], t.uses[start + (at >> 1)]));
				at += 2;
			}
		}
		for (count in [
			t.ints.length, t.floats.length, t.strings.length, t.files.length, t.types.length, t.typeImports.length,
			t.globals.length, t.globalImports.length, t.constants.length, t.functionImports.length, t.natives.length
		])
			reads.int(count);
		for (index in t.ints)
			reads.int(code.ints[index]);
		for (index in t.floats)
			reads.float(code.floats[index]);
		for (index in t.strings)
			reads.string(strings[index]);
		for (file in t.files)
			reads.string(file);
		for (index in t.types) {
			var home = typeHomes[index];
			reads.int(home == STRUCTURAL ? ROLE_STRUCTURAL : home == SHARED_DEFINITION ? ROLE_SHARED : ROLE_OWNED);
			if (home != STRUCTURAL)
				reads.string(typeKey(index));
			reads.type(localType(types[index]));
		}
		for (index in t.typeImports) {
			reads.int(kindOf(types[index]));
			reads.string(typeKey(index));
			reads.string(paths[typeHomes[index]]);
		}
		for (global in t.globals) {
			reads.int(local.types[globals[global]]);
			reads.string(globalKey(global));
		}
		for (global in t.globalImports) {
			reads.int(local.types[globals[global]]);
			reads.string(globalKey(global));
			reads.string(paths[globalHomes[global]]);
		}
		for (constant in t.constants) {
			var entry = code.constants[constant], fields = constantFields(globals[entry.global]);
			reads.int(local.types[globals[entry.global]]);
			reads.int(entry.fields.length);
			for (index in 0...entry.fields.length)
				reads.int(localField(fieldKind(fields[index].type), entry.fields[index]));
		}
		for (functionIndex in t.functionImports) {
			var position = functionPositions[functionIndex];
			reads.int(local.types[functionType(position)]);
			reads.string(code.functionNames[position]);
			reads.string(paths[functionHomes[position]]);
		}
		for (position in t.natives) {
			var native = code.natives[position];
			reads.string(strings[native.library]);
			reads.string(strings[native.name]);
			reads.int(local.types[native.type]);
		}
	}

	/** A constant's field value in the section's indices, by the kind of the field. */
	function localField(kind:Int, value:Int):Int
		return switch kind {
			case HlType.I32: local.ints[value];
			case HlType.Bool: value;
			case HlType.F64: local.floats[value];
			case HlType.Bytes: local.strings[value];
			case HlType.Type: local.types[value];
			default: local.globals[value];
		};

	// ---- encoding

	function encode(cache:HlSectionCache, modules:Map<String, Int>, declarations:DeclarationOwners,
			checkReuse:Bool, memoize:Bool):HlSectionOutput {
		assignHomes(cache, modules, declarations);
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
		var entries:Map<String, HlSectionEntry> = [],
			written:Array<HlSectionEntry> = [],
			linked = [for (_ in 0...functionPositions.length) -1],
			linkedNatives:Map<String, Int> = [],
			nativeCount = 0,
			nextFunction = 0,
			encoded = 0,
			changed = 0;
		for (id in 0...paths.length) {
			var owned = ownedFunctions[id], kept = cache.entries.get(paths[id]), entry:Null<HlSectionEntry> = null;
			if (kept != null && unchanged(kept, cache, owned, ownedTypes[id], ownedGlobals[id], snapshots[id])) {
				entry = kept;
				if (checkReuse) {
					collect(id, owned, ownedGlobals[id], ownedTypes[id]);
					settleIndices();
					if (sectionBytes(snapshots[id]).compare(kept.bytes) != 0)
						throw new InternalError('--check-reuse: section ${paths[id]} kept from the last build differs from one encoded afresh');
				}
			} else {
				collect(id, owned, ownedGlobals[id], ownedTypes[id]);
				settleIndices();
				var own = new HlSectionReads(), named = new HlSectionReads();
				if (memoize) {
					readOwn(own, owned, snapshots[id]);
					readNamed(named);
				}
				// What reads the same encodes the same; encoded to the same bytes, it is the section kept all the same, so
				// whatever holds it sees no change.
				var bytes = memoize && kept != null && own.equals(kept.own, spans)
					&& named.equals(kept.named, spans) ? kept.bytes : null;
				if (bytes == null) {
					bytes = sectionBytes(snapshots[id]);
					encoded++;
				} else if (checkReuse && sectionBytes(snapshots[id]).compare(bytes) != 0)
					throw new InternalError('--check-reuse: section ${paths[id]} kept from the last build differs from one encoded afresh');
				var same = kept != null && (bytes == kept.bytes || bytes.compare(kept.bytes) == 0);
				if (!same)
					changed++;
				entry = HlSectionEntry.of(own, named, {
					chain: relocations.chain,
					functions: [for (position in owned) code.functions[position]],
					ownedTypes: ownedTypes[id],
					ownedGlobals: ownedGlobals[id],
					imports: tables.functionImports,
					importTypes: [for (functionIndex in tables.functionImports)
						functionType(functionPositions[functionIndex])],
					nativeOrder: tables.nativeOrder
				}, bytes, same ? kept : null);
			}
			if (memoize)
				entries.set(paths[id], entry);
			written.push(entry);
			for (position in owned)
				linked[relocations.functionIndices[position]] = nextFunction++;
			for (key in entry.collected.nativeOrder)
				if (!linkedNatives.exists(key))
					linkedNatives.set(key, nativeCount++);
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
			var section = written[id];
			head.writeSizedString(paths[id]);
			head.output.writeInt32(offset);
			head.output.writeInt32(section.bytes.length);
			head.output.writeInt32(section.digestLow);
			head.output.writeInt32(section.digestHigh);
			offset += section.bytes.length;
		}
		head.writeSizedString(paths[functionHomes[entry]]);
		head.writeSizedString(functionKey(entry));
		for (section in written)
			head.writeShared(section.bytes);
		return {
			bytes: head.output.finish(),
			linkedIndices: linked,
			cache: cache.next(entries),
			sections: paths.length,
			encoded: encoded,
			changed: changed
		};
	}

	/**
	 * Whether the section owning the functions at `owned` is `kept` without collecting it: this build's tables extend the ones it
	 * was collected from (`HlRelocations.chain`), so every index it named names the same entry, its functions are the same
	 * objects naming their entries by those indices, it owns the same types and globals (a build of the run can add an enum
	 * tag or a global that a home puts here), the functions it imports have the types they had, the homes are the same, and its
	 * functions and snapshots read the same (`readOwn`).
	 */
	function unchanged(kept:HlSectionEntry, cache:HlSectionCache, owned:Array<Int>, ownedTypes:Array<Int>,
			ownedGlobals:Array<Int>, snapshots:Array<compiler.hl.HlCode.HlSourceSnapshot>):Bool {
		var collected = kept.collected;
		if (collected.chain != relocations.chain || !cache.sameHomes || collected.functions.length != owned.length
			|| !sameInts(collected.ownedTypes, ownedTypes) || !sameInts(collected.ownedGlobals, ownedGlobals))
			return false;
		for (index in 0...owned.length) {
			var position = owned[index];
			if (code.functions[position] != collected.functions[index] || relocations.moves[position])
				return false;
		}
		for (index in 0...collected.imports.length) {
			var position = functionPositions[collected.imports[index]];
			if (position < 0 || functionType(position) != collected.importTypes[index])
				return false;
		}
		kept.own.check();
		return readOwn(kept.own, owned, snapshots) && kept.own.complete();
	}

	static function sameInts(left:Array<Int>, right:Array<Int>):Bool {
		if (left.length != right.length)
			return false;
		for (index in 0...left.length)
			if (left[index] != right[index])
				return false;
		return true;
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
			local.functions[tables.functionImports[position]] = position;
		for (position in 0...tables.functions.length)
			local.functions[relocations.functionIndices[tables.functions[position]]] = functionImports + natives
				+ position;
		for (functionIndex in tables.nativeFunctions)
			local.functions[functionIndex] = functionImports + nativeSlots[functionIndex];
	}

	function sectionBytes(snapshots:Array<compiler.hl.HlCode.HlSourceSnapshot>):Bytes {
		var t = tables, w = new HlWriter(), out = w.output, path = paths[section];
		w.hasDebug = hasDebug;
		w.sources = code.sources;
		w.debugFileIndices = t.fileIndices;
		w.local = local;
		// The names are known once the heads are: the heads are written aside first, then the counts and the pool before them.
		var heads = new HlWriter();
		for (functionIndex in t.functionImports) {
			var position = functionPositions[functionIndex];
			heads.writeUnsignedIndex(t.name(paths[functionHomes[position]]));
			heads.writeUnsignedIndex(t.name(functionKey(position)));
			heads.writeUnsignedIndex(local.types[functionType(position)]);
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
			heads.writeUnsignedIndex(local.types[functionType(position)]);
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
			for (index in 0...entry.fields.length)
				w.writeUnsignedIndex(localField(fieldKind(fields[index].type), entry.fields[index]));
		}
		// Each function with its own indices, as the build that lowered it numbered what it names.
		w.local = functionLocal;
		for (index in 0...t.functions.length) {
			localizeFunction(index);
			w.writeFunction(code.functions[t.functions[index]]);
		}
		w.local = local;
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

/** The tables of the section being written, each by index in this build's dense table, in the section's order. */
private class HlSectionTables {
	public final names:Array<String> = [];
	/** Function indices. */
	public final functionImports:Array<Int> = [];
	public final globalImports:Array<Int> = [];
	public final typeImports:Array<Int> = [];

	/** Positions in `HlCode.natives`, one per library and name. */
	public final natives:Array<Int> = [];

	public final nativeKeys:Map<String, Int> = [];

	/** The keys of `natives`, in order. */
	public final nativeOrder:Array<String> = [];

	/** The function index of each native the section calls, in order of first use: several can share one of `natives`. */
	public final nativeFunctions:Array<Int> = [];
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

	/** For each of `functions`, where its entries in `uses` start. */
	public final useStarts:Array<Int> = [];

	/** By function then by `HlLoweredFunction.uses` entry, the index in the dense table of what the function names there. */
	public final uses:Array<Int> = [];

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

/**
 * What the sections of the last build were made from, for the next build to keep each section whose encoding would read the
 * same (`HlSectionWriter`). A section is one result, its bytes, kept while its reads (`HlSectionReads`) read the same and made
 * again otherwise, and kept as the same bytes when they come out equal: the query engine's `ModuleSection` query
 * (docs/design/QUERY_ENGINE.md, slice 7), whose reads are these. A build reads one and makes the next (`next`), so a failed
 * build leaves it as it was.
 */
@:allow(compiler.hl.HlSectionWriter)
class HlSectionCache {
	/** The sections, by path. */
	final entries:Map<String, HlSectionEntry>;

	/** The marks of the functions and snapshots validated (`HlValidator`), which hold while they are the same objects. */
	final validation:HlWriterCache;

	/** What the sections were encoded with besides their content (`HlSectionWriter.format`). */
	final format:String;

	/**
	 * The home module of each name (`HlSectionWriter.declaringModule`), while the declarations and modules are the ones in
	 * `declared` and `declaredModules`. A home is a function of the name and those alone, so the memo is shared by the builds
	 * that have them.
	 */
	final homes:Map<String, String>;

	final declared:Map<String, String>;
	final declaredModules:Map<String, Bool>;
	final declaredCount:Int;
	final moduleCount:Int;

	/** Whether the homes are the last build's: its declarations and modules were the same. */
	var sameHomes = false;

	/** The last file order of the sections (`orderOf`), with the set of them. */
	var order:Array<String> = [];

	var ordered:Map<String, Bool> = [];

	function new(entries, validation, format, homes, declared, declaredModules, declaredCount, moduleCount) {
		this.entries = entries;
		this.validation = validation;
		this.format = format;
		this.homes = homes;
		this.declared = declared;
		this.declaredModules = declaredModules;
		this.declaredCount = declaredCount;
		this.moduleCount = moduleCount;
	}

	/**
	 * The cache a build writes with after `previous`: its sections when they were encoded alike, its homes when the declarations
	 * are the same.
	 */
	static function following(previous:Null<HlSectionCache>, format:String, modules:Map<String, Int>,
			declarations:DeclarationOwners):HlSectionCache {
		var entries:Map<String, HlSectionEntry> = previous == null || previous.format != format ? [] : previous.entries,
			validation = previous == null ? new HlWriterCache() : previous.validation;
		if (previous != null && previous.declares(modules, declarations)) {
			var result = new HlSectionCache(entries, validation, format, previous.homes, previous.declared,
				previous.declaredModules, previous.declaredCount, previous.moduleCount);
			result.order = previous.order;
			result.ordered = previous.ordered;
			result.sameHomes = true;
			return result;
		}
		var declared:Map<String, String> = [],
			declaredModules:Map<String, Bool> = [],
			declaredCount = 0,
			moduleCount = 0;
		for (name => module in declarations) {
			declared.set(name, module);
			declaredCount++;
		}
		for (module in modules.keys()) {
			declaredModules.set(module, true);
			moduleCount++;
		}
		return new HlSectionCache(entries, validation, format, [], declared, declaredModules, declaredCount,
			moduleCount);
	}

	/** Whether the declarations and modules are the ones the homes were worked out for. */
	function declares(modules:Map<String, Int>, declarations:DeclarationOwners):Bool {
		var count = 0;
		for (name => module in declarations) {
			if (declared.get(name) != module)
				return false;
			count++;
		}
		if (count != declaredCount)
			return false;
		count = 0;
		for (module in modules.keys()) {
			if (!declaredModules.exists(module))
				return false;
			count++;
		}
		return count == moduleCount;
	}

	/** The section `name` belongs to: the module that declares what it is named after, or the shared section. */
	function homeOf(name:String, declarations:DeclarationOwners, modules:Map<String, Int>):String {
		var known = homes.get(name);
		if (known == null) {
			known = HlSectionWriter.declaringModule(name, declarations, modules) ?? HlSectionWriter.SHARED_SECTION;
			homes.set(name, known);
		}
		return known;
	}

	/** The sections `named` in file order: modules in path order (`StaticInitializationOrder.compareModules`), shared last. */
	function orderOf(named:Array<String>):Array<String> {
		var same = named.length == order.length;
		if (same)
			for (name in named)
				if (!ordered.exists(name)) {
					same = false;
					break;
				}
		if (same)
			return order;
		var modules = [for (name in named) if (name != HlSectionWriter.SHARED_SECTION) name];
		modules.sort(StaticInitializationOrder.compareModules);
		if (modules.length < named.length)
			modules.push(HlSectionWriter.SHARED_SECTION);
		order = modules;
		ordered = [for (name in modules) name => true];
		return order;
	}

	/** The cache after this one, with the sections of the build just written. */
	function next(written:Map<String, HlSectionEntry>):HlSectionCache {
		var result = new HlSectionCache(written, validation, format, homes, declared, declaredModules, declaredCount,
			moduleCount);
		result.order = order;
		result.ordered = ordered;
		return result;
	}
}

/** One section as written: its bytes and digest, with what its encoding read (`HlSectionWriter.readOwn`, `readNamed`). */
private class HlSectionEntry {
	public final own:HlSectionReads;
	public final named:HlSectionReads;
	public final collected:HlCollected;
	public final bytes:Bytes;

	/** The section's reuse key: two 32-bit FNV-1a hashes of its bytes, with different bases. */
	public final digestLow:Int;

	public final digestHigh:Int;

	function new(own:HlSectionReads, named:HlSectionReads, collected:HlCollected, bytes:Bytes, digestLow:Int,
			digestHigh:Int) {
		this.own = own;
		this.named = named;
		this.collected = collected;
		this.bytes = bytes;
		this.digestLow = digestLow;
		this.digestHigh = digestHigh;
	}

	/** The entry of `bytes`, with the digest of `same` when it holds the same bytes. */
	public static function of(own:HlSectionReads, named:HlSectionReads, collected:HlCollected, bytes:Bytes,
			same:Null<HlSectionEntry>):HlSectionEntry {
		if (same != null)
			return new HlSectionEntry(own, named, collected, same.bytes, same.digestLow, same.digestHigh);
		var low = 0x811C9DC5, high = 0x01000193 ^ bytes.length;
		for (index in 0...bytes.length) {
			var byte = bytes.get(index);
			low = (low ^ byte) * 0x01000193;
			high = (high ^ byte) * 0x01000197;
		}
		return new HlSectionEntry(own, named, collected, bytes, low, high);
	}
}

/**
 * What a section was collected from, in the indices of the run of builds whose tables it was collected from
 * (`HlRelocations.chain`): its functions, the types and globals it owns, the functions it imports with the type each had,
 * and the natives it names in order of first use. A build of the same run checks these to keep the section without collecting
 * it (`HlSectionWriter.unchanged`).
 */
private typedef HlCollected = {
	final chain:Int;
	final functions:Array<HlFunction>;
	final ownedTypes:Array<Int>;
	final ownedGlobals:Array<Int>;
	final imports:Array<Int>;
	final importTypes:Array<Int>;
	final nativeOrder:Array<String>;
}

/**
 * The values a section's encoding read (`HlSectionWriter.readOwn`, `readNamed`), recorded in order; then checked against what a later
 * build reads in the same order, which reads the same while `same` holds and `complete` says every value was read again.
 */
private class HlSectionReads {
	final ints:Array<Int> = [];
	final floats:Array<Float> = [];
	final strings:Array<String> = [];
	final types:Array<HlTypeDef> = [];
	final objects:Array<HlFunction> = [];
	var checking = false;
	var intAt = 0;
	var floatAt = 0;
	var stringAt = 0;
	var typeAt = 0;
	var objectAt = 0;

	public var same(default, null) = true;

	public function new() {}

	/** Starts checking the recorded values, from the first. */
	public function check():Void {
		checking = true;
		same = true;
		intAt = floatAt = stringAt = typeAt = objectAt = 0;
	}

	public function complete():Bool
		return same && intAt == ints.length && floatAt == floats.length && stringAt == strings.length
			&& typeAt == types.length && objectAt == objects.length;

	/** Whether `other`, recorded by a later build, read the same values; its functions compare as `object` does. */
	public function equals(other:HlSectionReads, spans:Bool):Bool {
		other.check();
		for (value in ints)
			other.int(value);
		for (value in floats)
			other.float(value);
		for (value in strings)
			other.string(value);
		for (value in types)
			other.type(value);
		for (value in objects)
			other.object(value, spans);
		return other.complete();
	}

	public function int(value:Int):Void
		if (!checking)
			ints.push(value);
		else {
			if (intAt >= ints.length || ints[intAt] != value)
				same = false;
			intAt++;
		}

	/** Floats by their bits, as the module pools them. */
	public function float(value:Float):Void
		if (!checking)
			floats.push(value);
		else {
			if (floatAt >= floats.length || !sameBits(floats[floatAt], value))
				same = false;
			floatAt++;
		}

	static function sameBits(left:Float, right:Float):Bool
		return HlSymbolTable.sameFloat(left, right)
			|| Math.isNaN(left) && Math.isNaN(right)
			&& haxe.io.FPHelper.doubleToI64(left) == haxe.io.FPHelper.doubleToI64(right);

	public function string(value:String):Void
		if (!checking)
			strings.push(value);
		else {
			if (stringAt >= strings.length || strings[stringAt] != value)
				same = false;
			stringAt++;
		}

	public function type(value:HlTypeDef):Void
		if (!checking)
			types.push(value);
		else {
			if (typeAt >= types.length || !HlSymbolTable.sameType(types[typeAt], value))
				same = false;
			typeAt++;
		}

	/**
	 * A function: the same object is the same code, and so is one lowered again to the same code up to the indices of what it
	 * names and the anchors its locations count from, which the reads after it compare (`HlSectionWriter.readNamed`). With
	 * `spans` the locations' columns and ranges are encoded too.
	 */
	public function object(value:HlFunction, spans:Bool):Void
		if (!checking)
			objects.push(value);
		else {
			if (objectAt >= objects.length || objects[objectAt] != value && !sameCode(objects[objectAt], value, spans))
				same = false;
			objectAt++;
		}

	static function sameCode(a:HlFunction, b:HlFunction, spans:Bool):Bool {
		if (HlFunctionEquality.difference(a, b, false) != null)
			return false;
		var x = a.debugLocations, y = b.debugLocations;
		if (x.length != y.length)
			return false;
		var forward:Map<Int, Int> = [], backward:Map<Int, Int> = [];
		for (index in 0...x.length) {
			var p = x[index], q = y[index], mapped = forward.get(p.anchor), origin = backward.get(q.anchor);
			if (mapped == null && origin == null) {
				forward.set(p.anchor, q.anchor);
				backward.set(q.anchor, p.anchor);
			} else if (mapped != q.anchor || origin != p.anchor)
				return false;
			if (p.line != q.line
				|| spans
				&& (p.column != q.column || p.endLine != q.endLine || p.endColumn != q.endColumn || p.start != q.start
				|| p.end != q.end || p.flags != q.flags || p.generatedText != q.generatedText))
				return false;
		}
		return true;
	}
}
