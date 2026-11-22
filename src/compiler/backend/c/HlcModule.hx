package compiler.backend.c;

import compiler.backend.c.HlcTypes.HlcUsage;
import compiler.core.InternalError;
import compiler.hl.HlCode;
import compiler.hl.HlType;
import compiler.hl.incremental.HlSymbolRequest.HlRemap;
import compiler.hl.incremental.HlSymbolTable;
import compiler.ir.model.Ir.IrObject;
import compiler.ir.model.Ir.IrProgram;
import compiler.ir.model.Ir.IrType;
import compiler.ir.model.IrBodyBuilder;
import compiler.ir.model.IrTypeIds;

/** One generated C file: its path in the output directory and its text. */
typedef HlcFile = {
	final path:String;
	final content:String;
}

/**
 * The C sources of one HashLink assembly (docs/design/AOT_BACKEND.md): `hlc.h` with what every file shares, one file per
 * Haxe source of the functions, each with the declarations it uses, and `image.c` (`HlcImage`) with the module image the
 * runtime builds its types from, the slot table and the layout checks. `code`, `symbols` and `slots` are the assembly's;
 * `program` is the program it lowered.
 */
@:allow(compiler.backend.c.HlcImage)
class HlcModule {
	public final code:HlCode;
	public final symbols:HlSymbolTable;
	public final types:HlcTypes;
	public var globalOffsets(default, null):Array<Int> = [];
	public final i32:Int;
	public final f64:Int;
	public final bool:Int;
	public final dyn:Int;
	public final typeRef:Int;

	final program:IrProgram;
	final slots:Map<String, Int>;
	final slotTypes:Array<Int> = [];
	final slotNames:Array<String> = [];
	final cNames:Array<String> = [];
	final cNameSlots:Map<String, Int> = [];
	final native:Array<Bool> = [];

	/** The C symbol of each native the program calls directly (by slot), null for those called through the slot table. */
	final nativeSymbols:Array<Null<String>> = [];
	final objects:Map<String, IrObject> = [];

	/** The program's objects and typed interface entries as `HlLower`'s analyses read them. */
	public final view:compiler.hl.lower.HlLoweringView;

	/** The program's ordinary C functions by name (`CNativeCall`). */
	public final cNatives:Map<String, compiler.ir.model.Ir.IrCNative> = [];

	/** Whether a function reads value arrays inline, which `hlc.h`'s view helper serves. */
	public var readsValueArrays = false;

	/** The object types allocated inline. */
	final allocationTypes:Map<Int, Bool> = [];

	/**
	 * Whether the functions are being collected (`HlcFunctionLower.collect`): their lowering interns what it uses and is
	 * handed no C names, as it writes nothing. `settleNames` ends it.
	 */
	var collecting = true;

	/**
	 * The type and global tables' lengths once the collection has interned everything the functions use (`emit`): lowering
	 * only reads the tables, and a type or global it would add is a difference between collecting and writing, reported as such.
	 */
	var typeLimit = 0x7FFFFFFF;

	var globalLimit = 0x7FFFFFFF;

	/** The C names of types, globals and natives (`HlcStableNames`), by table position, settled after the collection. */
	var typeNames:Array<String> = [];

	var globalNames:Array<String> = [];
	var allocationNames:Array<String> = [];
	var nativeNames:Array<Null<String>> = [];
	var nativePointers:Array<Null<String>> = [];

	/** What the text being written names (`use`), which its declarations are made from. */
	var usage:Null<HlcUsage>;

	/** What every file names, which `image.c` defines and the entry point fills. */
	final used = new HlcUsage();

	/** The source paths the `#line` directives name, as written, each with its C string literal. */
	final sourcePaths:Map<String, String> = [];

	/** The C string literal of `path` for a `#line` directive, recording that a directive names it. */
	public function linePath(path:String):String {
		var quoted = sourcePaths.get(path);
		if (quoted == null) {
			quoted = quote(path);
			sourcePaths.set(path, quoted);
		}
		return quoted;
	}

	/** Whether objects are allocated inline (`CompileOptions.inlineAllocation`), else by `hl_alloc_obj`. */
	public final inlineAllocation:Bool;

	public function new(code:HlCode, symbols:HlSymbolTable, program:IrProgram, slots:Map<String, Int>,
			inlineAllocation:Bool) {
		this.code = code;
		this.inlineAllocation = inlineAllocation;
		this.symbols = symbols;
		this.program = program;
		this.slots = slots;
		types = new HlcTypes(code);
		i32 = symbols.internType(IrType.I32);
		f64 = symbols.internType(IrType.F64);
		bool = symbols.internType(IrType.Bool);
		dyn = symbols.internType(IrType.Dyn);
		typeRef = symbols.internType(IrType.TypeRef);
		for (object in program.objects)
			objects.set(object.name, object);
		view = new compiler.hl.lower.HlLoweringView(new compiler.hl.lower.HlTypedInterfaceTables(program).keys,
			objects);
		for (native in program.cNatives)
			cNatives.set(native.name, native);
		for (fn in code.functions)
			place(fn.functionIndex, fn.type, false);
		for (entry in code.natives) {
			place(entry.functionIndex, entry.type, true);
			nativeSymbols[entry.functionIndex] = nativeSymbol(code.strings[entry.library], code.strings[entry.name]);
		}
		for (name => slot in slots)
			if (slot < slotNames.length)
				slotNames[slot] = name;
		// By the function's name, so a function keeps its C name when others are added or removed.
		var named = [for (slot in 0...slotTypes.length) slotNames[slot] == null ? 'slot$slot' : slotNames[slot]];
		var unique = HlcStableNames.unique([for (name in named) "hx_" + HlcStableNames.part(name)], named);
		for (slot in 0...slotTypes.length) {
			cNames[slot] = unique[slot];
			if (!native[slot])
				cNameSlots.set(unique[slot], slot);
		}
	}

	function place(slot:Int, type:Int, isNative:Bool):Void {
		while (slotTypes.length <= slot) {
			slotTypes.push(-1);
			slotNames.push(null);
			native.push(false);
		}
		slotTypes[slot] = type;
		native[slot] = isNative;
	}

	/** A C identifier for a Haxe name. */
	public static function identifier(name:String):String {
		var buffer = new StringBuf();
		for (index in 0...name.length) {
			var code = StringTools.fastCodeAt(name, index);
			var valid = (code >= "a".code && code <= "z".code) || (code >= "A".code && code <= "Z".code)
				|| (code >= "0".code && code <= "9".code) || code == "_".code;
			buffer.addChar(valid ? code : "_".code);
		}
		return buffer.toString();
	}

	/** A C string literal of `text`, for `#line` and messages. */
	public static function quote(text:String):String {
		var buffer = new StringBuf();
		buffer.addChar('"'.code);
		for (index in 0...text.length) {
			var code = StringTools.fastCodeAt(text, index);
			if (code == '"'.code || code == "\\".code) {
				buffer.addChar("\\".code);
				buffer.addChar(code);
			} else if (code < 32 || code > 126)
				buffer.add("\\" + StringTools.hex(code >> 6 & 7) + StringTools.hex(code >> 3 & 7)
					+ StringTools.hex(code & 7));
			else
				buffer.addChar(code);
		}
		buffer.addChar('"'.code);
		return buffer.toString();
	}

	public function requireSlot(name:String):Int {
		var slot = slots.get(name);
		if (slot == null || slot >= slotTypes.length || slotTypes[slot] < 0)
			throw new InternalError('C backend: no function slot for $name');
		return slot;
	}

	public inline function slotType(slot:Int):Int
		return slotTypes[slot];

	public function slotName(slot:Int):String
		return slotNames[slot] == null ? 'slot $slot' : slotNames[slot];

	public function slotArguments(slot:Int):Array<Int>
		return types.signature(slotTypes[slot]).arguments;

	public function slotArgument(slot:Int, index:Int):Int
		return slotArguments(slot)[index];

	public function slotResult(slot:Int):Int
		return types.signature(slotTypes[slot]).result;

	/**
	 * The C function a native of `library` is, by the convention of its library's `HL_NAME`: the VM's own natives are `hl_`,
	 * the Haxeon runtime's `realtime_`. Natives of other libraries, which load at run time, are called through the slot table.
	 */
	static function nativeSymbol(library:String, name:String):Null<String>
		return switch library {
			case "std": "hl_" + name;
			case "haxeon_runtime": "realtime_" + name;
			default: null;
		};

	/**
	 * What a C call of slot `slot` calls: the function itself, or a native under a name of its own (`nativeDeclaration`): a
	 * native of the VM or the runtime by its C symbol, so its C types never meet `hl.h`'s, another through the pointer the
	 * runtime resolved.
	 */
	public function functionPointer(slot:Int):String {
		if (collecting)
			return "";
		var text = usage;
		if (native[slot]) {
			if (text != null)
				text.natives.set(slot, true);
			return nativeNames[slot];
		}
		if (text != null)
			text.functions.set(slot, true);
		return cNames[slot];
	}

	/** Records what the C text written from now on names in `text`. */
	function use(text:HlcUsage):Void {
		usage = text;
		types.usage = text;
	}

	/** The HashLink type of `type`, interned while the functions are collected and only looked up after. */
	public function typeIndex(type:IrType):Int
		return collected(HlRemap.typeIndex(symbols, type), 'type $type');

	/** The runtime header type `kind` (`HlSymbolTable.internRuntimeHeader`), as `typeIndex`. */
	public function runtimeHeader(kind:compiler.hl.incremental.HlSymbolRequest.HlRuntimeHeader):Int
		return collected(symbols.internRuntimeHeader(kind), 'runtime header $kind');

	/** The global holding String literal `value`, interned while the functions are collected and only looked up after. */
	public function stringConstant(value:String):Int {
		var global = symbols.internStringConstant(value);
		if (global >= globalLimit)
			throw new InternalError('C backend: the String literal global of "$value" was not collected before lowering');
		return global;
	}

	/** The global caching enum `name`'s constructor `constructor` without fields, as `stringConstant`. */
	public function enumConstant(name:String, constructor:Int):Int {
		var global = symbols.internEnumConstant(name, constructor);
		if (global >= globalLimit)
			throw new InternalError('C backend: the global of $name constructor $constructor was not collected before lowering');
		return global;
	}

	function collected(type:Int, what:String):Int {
		if (type >= typeLimit)
			throw new InternalError('C backend: HashLink $what was not collected before lowering');
		return type;
	}

	/** The descriptor of type `type` (`hl_type*`), a pointer the entry point sets before anything runs (`HlcImage`). */
	public function typeDescriptor(type:Int):String {
		if (collecting)
			return "";
		if (usage != null)
			usage.types.set(type, true);
		return typeNames[type];
	}

	/** The address of global `global`'s value (`void*`), a pointer the entry point sets before anything runs (`HlcImage`). */
	public function globalPointer(global:Int):String {
		if (collecting)
			return "";
		if (usage != null)
			usage.globals.set(global, true);
		return globalNames[global];
	}

	/**
	 * The inline allocation descriptor of object type `type` (`hl_jit_alloc_data`), recorded while the functions are collected:
	 * the entry point fills it with the collector's own description of the fast path (`hl_jit_alloc_prepare`) before anything
	 * runs.
	 */
	public function allocation(type:Int):String {
		if (collecting) {
			allocationTypes.set(type, true);
			return "";
		}
		if (!allocationTypes.exists(type))
			throw new InternalError('C backend: the inline allocation of ${types.typeName(type)} was not collected before lowering');
		if (usage != null)
			usage.allocations.set(type, true);
		return allocationNames[type];
	}

	/** Settles every C name once the collection has interned all that the functions use. */
	function settleNames():Void {
		collecting = false;
		typeLimit = symbols.types.length;
		globalLimit = symbols.globals.length;
		if (code.types.length != typeLimit || code.globals.length != globalLimit)
			throw new InternalError("C backend: the module's tables are not the symbol table's");
		globalOffsets = types.globalOffsets();
		var names = new HlcStableNames(code, symbols.namedGlobals());
		types.structNames = [for (name in names.types) "hlc_obj_" + name];
		typeNames = [for (name in names.types) "hlc_t_" + name];
		allocationNames = [for (name in names.types) "hlc_a_" + name];
		globalNames = [for (name in names.globals) "hlc_g_" + name];
		nativeNames = [for (slot in 0...slotTypes.length) native[slot]
			? "hlc_native_" + names.natives.get(slot) : null];
		nativePointers = [for (slot in 0...slotTypes.length) native[slot] ? "hlc_np_" + names.natives.get(slot) : null];
	}

	/** The C declarator of the function in slot `slot`, its parameters named `names` (or left unnamed). */
	public function prototype(slot:Int, ?names:Array<String>):String {
		var signature = types.signature(slotTypes[slot]);
		var parameters = [
			for (index in 0...signature.arguments.length)
				types.cType(signature.arguments[index]) + (names == null ? "" : " " + names[index])
		];
		return '${types.cType(signature.result)} ${cNames[slot]}(${parameters.length == 0 ? "void" : parameters.join(", ")})';
	}

	/** The function a value class's method `name` is, called directly as `HlLower` calls it; null for other receivers. */
	public function valueMethod(type:IrType, name:String):Null<String> {
		var object = switch type {
			case Obj(objectName): objects.get(objectName);
			default: null;
		};
		if (object == null || !object.isValue)
			return null;
		for (method in object.methods)
			if (method.name == name)
				return method.functionName.name;
		return null;
	}

	/** The native storage of field `name` of object type `type` or a base (`IrFieldStorage.scalar`), or null. */
	public function fieldStorage(type:IrType, name:String):Null<compiler.ir.model.Ir.IrScalarStorage> {
		var owner = switch type {
			case Obj(objectName): objects.get(objectName);
			default: null;
		};
		while (owner != null) {
			for (field in owner.fields)
				if (field.name == name)
					return compiler.ir.model.IrFieldStorage.scalar(field);
			owner = owner.base == null ? null : objects.get(Std.string(owner.base));
		}
		return null;
	}

	/** The slot of the function at prototype slot `index` of object type `type` or its nearest base that has it. */
	public function prototypeFunction(type:Int, index:Int):Int {
		var current = type;
		while (current >= 0)
			switch code.types[current] {
				case Object(_, base, _, _, methods, _):
					for (method in methods)
						if (method.prototype == index)
							return method.functionIndex;
					current = base;
				default:
					break;
			}
		throw new InternalError('C backend: no method at prototype slot $index of ${types.typeName(type)}');
	}

	/** Whether slot `slot` has the signature the runtime takes as an object's `__compare` (`hl_get_obj_rt`). */
	public function isCompare(slot:Int):Bool {
		var signature = types.signature(slotTypes[slot]);
		return signature.arguments.length == 2 && types.kind(signature.arguments[1]) == HlType.Dyn
			&& types.kind(signature.result) == HlType.I32;
	}

	/** Lowers every function of the program and writes the files. */
	public function emit():Array<HlcFile> {
		// The program's table: every body of a program shares one (`IrStageHooks`), so one lowered here reads its ids as the rest.
		var lowering = new HlcFunctionLower(this),
			bodyTypes = IrTypeIds.ofFunctions(program.functions),
			builder = new IrBodyBuilder(new IrTypeIds()),
			files:Map<String, StringBuf> = [],
			fileOrder:Array<String> = [];
		var functions = [for (fn in program.functions) if (slots.exists(fn.name) && !native[slots.get(fn.name)]) fn];
		functions.sort((a, b) -> slots.get(a.name) - slots.get(b.name));
		var defined:Map<Int, Bool> = [];
		var bodies = [for (fn in functions) fn.bodyIn(bodyTypes, builder)];
		// Everything the functions use is interned first, in slot order, so the names are settled before any C is written and
		// lowering only reads the tables.
		for (index in 0...functions.length)
			try
				lowering.collect(bodies[index], slots.get(functions[index].name))
			catch (error:HlcFunctionLower.HlcUnsupported)
				throw error
			catch (error:InternalError)
				throw new InternalError('C backend, collecting ${bodies[index].name}: ${error.message}');
		settleNames();
		var fileNames = sourceFiles(bodies), usages:Map<String, HlcUsage> = [];
		// A module's functions are split into files of about FILE_SIZE characters, which compile in parallel: a C compiler's
		// time grows with a file's functions, and the largest modules would otherwise be the whole build's time.
		var parts:Map<String, Int> = [];
		for (index in 0...functions.length) {
			var body = bodies[index], slot = slots.get(functions[index].name), module = fileNames[index];
			var part = parts.exists(module) ? parts.get(module) : 1;
			var file = part == 1 ? module : haxe.io.Path.withoutExtension(module) + '.part$part.c';
			var buffer = files.get(file);
			if (buffer != null && buffer.length >= FILE_SIZE) {
				parts.set(module, ++part);
				file = haxe.io.Path.withoutExtension(module) + '.part$part.c';
				buffer = null;
			}
			var fileUsage = usages.get(file);
			if (buffer == null || fileUsage == null) {
				buffer = new StringBuf();
				fileUsage = new HlcUsage();
				files.set(file, buffer);
				usages.set(file, fileUsage);
				fileOrder.push(file);
			}
			// A file declares its own functions too: the prototype puts each in the generated code's section (`HLC_FUNCTION`).
			use(fileUsage);
			fileUsage.functions.set(slot, true);
			try
				lowering.lower(body, slot, buffer)
			catch (error:HlcFunctionLower.HlcUnsupported)
				throw error
			catch (error:InternalError)
				throw new InternalError('C backend, lowering ${body.name}: ${error.message}');
			defined.set(slot, true);
		}
		for (slot in 0...slotTypes.length)
			if (slotTypes[slot] >= 0 && !native[slot] && !defined.exists(slot))
				throw new InternalError('C backend: slot $slot (${slotName(slot)}) has no IR function');
		var result:Array<HlcFile> = [{path: "hlc.h", content: header()}];
		fileOrder.sort(Reflect.compare);
		for (file in fileOrder) {
			var text = files.get(file), names = usages.get(file);
			if (text == null || names == null)
				throw new InternalError('C backend: no text for $file');
			result.push({path: file, content: withDeclarations(text.toString(), names)});
		}
		var imageUsage = new HlcUsage();
		use(imageUsage);
		result.push({path: "image.c", content: withDeclarations(new HlcImage(this).write(), imageUsage)});
		use(null);
		return result;
	}

	static final INCLUDE = '#include "hlc.h"\n\n';
	static inline final FILE_SIZE = 600000;

	/** Each function's file: the Haxe source most of its rows come from, so functions group by module. */
	function sourceFiles(bodies:Array<compiler.ir.model.IrBody>):Array<String> {
		var paths:Array<String> = [];
		for (body in bodies) {
			var counts:Map<String, Int> = [], best = "", bestCount = 0;
			for (block in 0...body.blockCount()) {
				var row = body.firstRow(block);
				while (row >= 0) {
					var location = body.provenance(row).location;
					if (location != null) {
						var count = (counts.exists(location.path) ? counts.get(location.path) : 0) + 1;
						counts.set(location.path, count);
						if (count > bestCount || count == bestCount && location.path < best) {
							best = location.path;
							bestCount = count;
						}
					}
					row = body.nextRow(row);
				}
			}
			paths.push(best);
		}
		var distinct = [for (path in paths) path => true], names:Map<String, String> = [], taken:Map<String, Bool> = [];
		var sorted = [for (path in distinct.keys()) path];
		sorted.sort(Reflect.compare);
		for (path in sorted) {
			var base = path == "" ? "generated" : haxe.io.Path.withoutExtension(haxe.io.Path.withoutDirectory(path));
			var name = identifier(base), suffix = 1;
			while (taken.exists(name.toLowerCase()) || name == "image" || name == "hlc")
				name = identifier(base) + "_" + (++suffix);
			taken.set(name.toLowerCase(), true);
			names.set(path, name + ".c");
		}
		return [for (path in paths) names.get(path)];
	}

	/**
	 * `hlc.h`: the SDK's `hlc_prelude.h`, what every program's C shares, with this program's options defined before it, and
	 * after it what depends on the program.
	 */
	function header():String {
		var buffer = new StringBuf();
		buffer.add("/* Generated by Haxeon's C backend (docs/design/AOT_BACKEND.md). */\n");
		buffer.add("#ifndef HLC_GENERATED_H\n#define HLC_GENERATED_H\n");
		if (inlineAllocation)
			buffer.add("#define HLC_INLINE_ALLOCATION\n");
		buffer.add("#include <hlc_prelude.h>\n\n");
		if (readsValueArrays) {
			var helper = new StringBuf();
			var helperUsage = new HlcUsage();
			use(helperUsage);
			valueArrayHelper(helper);
			buffer.add(withDeclarations(helper.toString(), helperUsage, false));
		}
		buffer.add("\n#endif\n");
		return buffer.toString();
	}

	/**
	 * A native under a name of its own (`functionPointer`): with gcc and clang a native of the VM or the runtime is its C symbol
	 * (an asm label), with MSVC's compilers on 64-bit Windows the linker binds the name to it (`/alternatename`, as C symbols
	 * there have no prefix), else the native is the pointer the runtime resolved for its slot, which the entry point copies to
	 * `hlc_np_` before anything runs (`HlcImage`).
	 */
	function nativeDeclaration(slot:Int, buffer:StringBuf):Void {
		var signature = types.signature(slotTypes[slot]);
		var result = types.cType(signature.result),
			arguments = [for (type in signature.arguments) types.cType(type)].join(",");
		if (arguments == "")
			arguments = "void";
		var name = nativeNames[slot], pointer = nativePointers[slot];
		buffer.add('extern void *$pointer;\n');
		if (nativeSymbols[slot] != null)
			buffer.add('#if defined(__GNUC__)\nextern $result $name($arguments) HLC_SYMBOL("${nativeSymbols[slot]}");\n'
				+ '#elif defined(_MSC_VER) && defined(_WIN64)\nextern $result $name($arguments);\n'
				+ '#pragma comment(linker, "/alternatename:$name=${nativeSymbols[slot]}")\n#else\n');
		buffer.add('#define $name (($result (*)($arguments))$pointer)\n');
		if (nativeSymbols[slot] != null)
			buffer.add("#endif\n");
	}

	/**
	 * C text `text` with the declarations of what it names (`text`'s usage, recorded while it was written) before it: the
	 * typedefs and definitions of its structs, the type descriptors, globals and allocation descriptors it reads, the natives
	 * it calls and the prototypes of the generated functions it names, each kind sorted by name. Each file declares only what
	 * it uses, so a file is not compiled again when a declaration it does not use changes, and no file parses the whole
	 * program's. The declarations record the structs they name in turn.
	 */
	function withDeclarations(text:String, names:HlcUsage, include = true):String {
		use(names);
		var calls = new StringBuf();
		var natives = sorted(names.natives, slot -> nativeNames[slot]),
			functions = sorted(names.functions, slot -> cNames[slot]);
		for (slot in natives)
			nativeDeclaration(slot, calls);
		for (slot in functions)
			calls.add('HLC_FUNCTION ${prototype(slot)}; /* ${slotName(slot)} */\n');
		var structNames:Array<String> = types.structNames, definitions = new StringBuf();
		types.structDefinitions(sorted(names.structs, index -> structNames[index]), definitions);
		use(null);
		var buffer = new StringBuf();
		if (include)
			buffer.add(INCLUDE);
		// The definitions name the structs of their fields, which need typedefs too.
		for (index in sorted(names.structs, index -> structNames[index]))
			buffer.add('typedef struct ${structNames[index]} ${structNames[index]};\n');
		buffer.add(definitions.toString());
		for (index in sorted(names.types, index -> typeNames[index]))
			buffer.add('extern hl_type *${typeNames[index]};\n');
		for (index in sorted(names.globals, index -> globalNames[index]))
			buffer.add('extern void *${globalNames[index]};\n');
		for (index in sorted(names.allocations, index -> allocationNames[index]))
			buffer.add('extern hl_jit_alloc_data ${allocationNames[index]};\n');
		buffer.add(calls.toString());
		buffer.add("\n");
		buffer.add(text);
		for (index in names.types.keys())
			used.types.set(index, true);
		for (index in names.globals.keys())
			used.globals.set(index, true);
		for (index in names.natives.keys())
			used.natives.set(index, true);
		return buffer.toString();
	}

	/** The indices of `set` sorted by their C names, so declarations are in the same order in every build. */
	static function sorted(set:Map<Int, Bool>, name:Int->String):Array<Int> {
		var keyed = [for (index in set.keys()) {
			index:index, name:name(index)
		}];
		keyed.sort((a, b) -> Reflect.compare(a.name, b.name));
		return [for (entry in keyed) entry.index];
	}

	/**
	 * `hlc_value_array_view`: the value array a header leads to, as `HlLower.resolveValueArrayView` resolves it (the header
	 * itself, or a forwarding header's data; null for anything else), and its stride in bytes.
	 */
	function valueArrayHelper(buffer:StringBuf):Void {
		var header = functionPointer(requireSlot(compiler.hl.lower.HlLower.VALUE_ARRAY_HEADER_TYPE)),
			forward = functionPointer(requireSlot(compiler.hl.lower.HlLower.VALUE_ARRAY_FORWARD_TYPE));
		buffer.add("static hl_type *hlc_value_array_header_t, *hlc_value_array_forward_t;\n");
		buffer.add("static inline vbyte *hlc_value_array_view( void *header, int *stride ) {\n");
		buffer.add("\thl_type *t = header ? ((vdynamic*)header)->t : &hlt_void;\n\tvbyte *a;\n");
		buffer.add('\tif( !hlc_value_array_header_t ) hlc_value_array_header_t = (hl_type*)$header();\n');
		buffer.add("\tif( t == hlc_value_array_header_t ) a = (vbyte*)header;\n\telse {\n");
		buffer.add('\t\tif( !hlc_value_array_forward_t ) hlc_value_array_forward_t = (hl_type*)$forward();\n');
		buffer.add('\t\tif( t != hlc_value_array_forward_t ) return NULL;\n');
		buffer.add('\t\ta = *(vbyte**)((vbyte*)header + ${compiler.hl.lower.HlLower.ARRAY_DATA_OFFSET});\n\t}\n');
		buffer.add('\tif( a ) *stride = (int)(*(unsigned int*)(a + ${compiler.hl.lower.HlLower.VALUE_ARRAY_STRIDE_OFFSET}) >> 3);\n');
		buffer.add("\treturn a;\n}\n\n");
	}
}
