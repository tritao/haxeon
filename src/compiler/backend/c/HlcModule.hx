package compiler.backend.c;

import compiler.core.InternalError;
import compiler.hl.HlCode;
import compiler.hl.HlFunction;
import compiler.hl.HlType;
import compiler.hl.HlWriter;
import compiler.hl.incremental.HlSymbolTable;
import compiler.ir.Ir.IrObject;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.ir.IrBodyBuilder;
import compiler.ir.IrTypeIds;

/** One generated C file: its path in the output directory and its text. */
typedef HlcFile = {
	final path:String;
	final content:String;
}

/**
 * The C sources of one HashLink assembly (docs/design/AOT_BACKEND.md): `hlc.h` with the object structs and function
 * prototypes, one file per Haxe source of the functions, and `image.c` with the module image the runtime builds its types
 * from, the slot table and the layout checks. `code`, `symbols` and `slots` are the assembly's; `program` is the program it
 * lowered.
 */
class HlcModule {
	public final code:HlCode;
	public final symbols:HlSymbolTable;
	public final types:HlcTypes;
	public final globalOffsets:Array<Int>;
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
	final native:Array<Bool> = [];

	/** The C symbol of each native the program calls directly (by slot), null for those called through the slot table. */
	final nativeSymbols:Array<Null<String>> = [];
	final objects:Map<String, IrObject> = [];

	/** The program's objects and typed interface entries as `HlLower`'s analyses read them. */
	public final view:compiler.hl.lower.HlLoweringView;

	/** The program's ordinary C functions by name (`CNativeCall`). */
	public final cNatives:Map<String, compiler.ir.Ir.IrCNative> = [];

	/** Whether a function reads value arrays inline, which `hlc.h`'s view helper serves. */
	public var readsValueArrays = false;

	/** The object types allocated inline, each with its descriptor's index in `hlc_alloc_data`. */
	final allocationTypes:Array<Int> = [];

	final allocationIndices:Map<Int, Int> = [];

	/** The source paths the `#line` directives name, as written. */
	final sourcePaths:Map<String, Bool> = [];

	/** Records that a `#line` directive names `path`. */
	public function useSourcePath(path:String):Void
		sourcePaths.set(path, true);

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
		var used:Map<String, Bool> = [];
		for (slot in 0...slotTypes.length) {
			var name = slotNames[slot] == null ? 'slot$slot' : slotNames[slot],
				cName = "hx_" + identifier(name);
			if (used.exists(cName))
				cName += "_" + slot;
			used.set(cName, true);
			cNames[slot] = cName;
		}
		globalOffsets = types.globalOffsets();
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
	 * What a C call of slot `slot` calls: the function itself, a native of the VM or the runtime by its C symbol (declared in
	 * `hlc.h` under a name of its own, so its C types never meet `hl.h`'s), or another native through the slot table.
	 */
	public function functionPointer(slot:Int):String {
		if (!native[slot])
			return cNames[slot];
		if (nativeSymbols[slot] != null)
			return 'hlc_native_$slot';
		var signature = types.signature(slotTypes[slot]);
		var arguments = [for (type in signature.arguments) types.cType(type)];
		return '((${types.cType(signature.result)} (*)(${arguments.length == 0 ? "void" : arguments.join(",")}))hlc_slots[$slot])';
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
	public function fieldStorage(type:IrType, name:String):Null<compiler.ir.Ir.IrScalarStorage> {
		var owner = switch type {
			case Obj(objectName): objects.get(objectName);
			default: null;
		};
		while (owner != null) {
			for (field in owner.fields)
				if (field.name == name)
					return compiler.ir.IrFieldStorage.scalar(field);
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

	/**
	 * The index of type `type`'s inline allocation descriptor in `hlc_alloc_data`, which the entry point fills with the
	 * collector's own description of the fast path (`hl_jit_alloc_prepare`) before anything runs.
	 */
	public function allocationIndex(type:Int):Int {
		var index = allocationIndices.get(type);
		if (index == null) {
			index = allocationTypes.length;
			allocationTypes.push(type);
			allocationIndices.set(type, index);
		}
		return index;
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
		var fileNames = sourceFiles(bodies);
		for (index in 0...functions.length) {
			var body = bodies[index], slot = slots.get(functions[index].name), file = fileNames[index];
			var buffer = files.get(file);
			if (buffer == null) {
				buffer = new StringBuf();
				buffer.add('#include "hlc.h"\n\n');
				files.set(file, buffer);
				fileOrder.push(file);
			}
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
		// The header comes last: lowering may intern types (a cast's target) that the structs and the image must have.
		var result:Array<HlcFile> = [{path: "hlc.h", content: header()}];
		fileOrder.sort(Reflect.compare);
		for (file in fileOrder)
			result.push({path: file, content: files.get(file).toString()});
		result.push({path: "image.c", content: image()});
		return result;
	}

	/** Each function's file: the Haxe source most of its rows come from, so functions group by module. */
	function sourceFiles(bodies:Array<compiler.ir.IrBody>):Array<String> {
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

	function header():String {
		var buffer = new StringBuf();
		buffer.add("/* Generated by Haxeon's C backend (docs/design/AOT_BACKEND.md). */\n");
		buffer.add("#ifndef HLC_GENERATED_H\n#define HLC_GENERATED_H\n");
		buffer.add("#include <math.h>\n#include <string.h>\n#include <stddef.h>\n#include <hl.h>\n\n");
		buffer.add("#if defined(__GNUC__)\n");
		buffer.add("#pragma GCC diagnostic ignored \"-Wunused-label\"\n");
		buffer.add("#pragma GCC diagnostic ignored \"-Wunused-variable\"\n");
		buffer.add("#pragma GCC diagnostic ignored \"-Wunused-but-set-variable\"\n");
		buffer.add("#endif\n\n");
		// The program's functions are in a section of their own, which tells the stack capture its frames (`hlc_stack.c`). A
		// development build (HLC_EXACT_FRAMES, `HlcBuild`) does not let the C compiler inline them into each other, so a Haxe stack
		// trace has the JIT's frames exactly; a release build does, and the stack capture restores the inlined frames from DWARF.
		buffer.add("#if defined(HLC_EXACT_FRAMES) && defined(__GNUC__)\n#define HLC_NOINLINE __attribute__((noinline))\n");
		buffer.add("#else\n#define HLC_NOINLINE\n#endif\n");
		buffer.add("#if defined(__ELF__) && defined(__GNUC__)\n");
		buffer.add("#define HLC_FUNCTION __attribute__((section(\"hlc_text\"))) HLC_NOINLINE\n");
		buffer.add("#else\n#define HLC_FUNCTION HLC_NOINLINE\n#endif\n\n");
		buffer.add("extern hl_type *hlc_types;\nextern unsigned char *hlc_globals;\nextern void **hlc_slots;\n");
		buffer.add("void hl_jit_null_field_access( int fhash );\n");
		buffer.add("extern hl_jit_alloc_data hlc_alloc_data[];\n");
		buffer.add("typedef struct { const char *key; void *(*call)( void *f, void **a, vdynamic *out ); void *wrap; } hlc_signature;\n");
		buffer.add("static inline double hlc_f64( unsigned int high, unsigned int low ) {\n");
		buffer.add("\tunsigned long long bits = ((unsigned long long)high << 32) | low; double value;\n");
		buffer.add("\tmemcpy(&value,&bits,sizeof(value)); return value;\n}\n\n");
		if (inlineAllocation)
			buffer.add(ALLOCATION_HELPER);
		types.structDeclarations(buffer);
		buffer.add("\n");
		for (slot in 0...slotTypes.length)
			if (slotTypes[slot] >= 0 && !native[slot])
				buffer.add('HLC_FUNCTION ${prototype(slot)}; /* ${slotName(slot)} */\n');
		buffer.add("\n#if defined(__GNUC__)\n#define HLC_STRING2(x) #x\n#define HLC_STRING(x) HLC_STRING2(x)\n");
		// Weak where the linker allows it: a native the libraries lack is the loader's error at start-up, as for the JIT, not a
		// link error.
		buffer.add("#if defined(__ELF__)\n#define HLC_SYMBOL(name) __asm__(HLC_STRING(__USER_LABEL_PREFIX__) name) __attribute__((weak))\n");
		buffer.add("#else\n#define HLC_SYMBOL(name) __asm__(HLC_STRING(__USER_LABEL_PREFIX__) name)\n#endif\n#endif\n");
		for (slot in 0...slotTypes.length)
			if (slotTypes[slot] >= 0 && native[slot] && nativeSymbols[slot] != null) {
				var signature = types.signature(slotTypes[slot]);
				var result = types.cType(signature.result),
					arguments = [for (type in signature.arguments) types.cType(type)].join(",");
				if (arguments == "")
					arguments = "void";
				buffer.add('#if defined(__GNUC__)\nextern $result hlc_native_$slot($arguments) HLC_SYMBOL("${nativeSymbols[slot]}");\n');
				buffer.add('#else\n#define hlc_native_$slot (($result (*)($arguments))hlc_slots[$slot])\n#endif\n');
			}
		if (readsValueArrays)
			valueArrayHelper(buffer);
		buffer.add("\n#endif\n");
		return buffer.toString();
	}

	/**
	 * `hlc_new`: an object allocated from the thread's allocation buffer as the JIT's inline allocation does, by the
	 * descriptor the collector gave for its type (`hl_jit_alloc_data`), and through the collector's slow path otherwise. Where
	 * the collector gives no descriptor (other targets, debug collectors) the descriptor is empty and `hl_alloc_obj` allocates.
	 */
	static final ALLOCATION_HELPER =
		"#if defined(__GNUC__) && defined(__linux__) && (defined(__x86_64__) || defined(__aarch64__))\n"
		+ "#define HLC_INLINE_ALLOC\n"
		+ "static inline unsigned char *hlc_thread_pointer( void ) {\n"
		+ "\tunsigned char *p;\n"
		+ "#if defined(__x86_64__)\n"
		+ "\t__asm__(\"mov %%fs:0,%0\" : \"=r\"(p));\n"
		+ "#else\n"
		+ "\t__asm__(\"mrs %0, tpidr_el0\" : \"=r\"(p));\n"
		+ "#endif\n"
		+ "\treturn p;\n}\n"
		+ "#endif\n"
		+ "static inline void *hlc_new( hl_jit_alloc_data *d, hl_type *t ) {\n"
		+ "#ifdef HLC_INLINE_ALLOC\n"
		+ "\tif( !d->type ) return hl_alloc_obj(t);\n"
		+ "\tfor(int i=0;i<d->nguards;i++) {\n"
		+ "\t\thl_jit_alloc_guard *g = d->guards + i;\n"
		+ "\t\tuint64 v = g->bytes == 1 ? *(volatile unsigned char*)g->address : g->bytes == 4 ? *(volatile unsigned int*)g->address : *(volatile uint64*)g->address;\n"
		+ "\t\tif( v & g->mask ) return hl_jit_alloc_slow(t);\n"
		+ "\t}\n"
		+ "\tif( !d->runtime->allocation_ready ) return hl_jit_alloc_slow(t);\n"
		+ "\tunsigned char *th = *(unsigned char**)(hlc_thread_pointer() + d->tls_offset);\n"
		+ "\tif( !th ) return hl_jit_alloc_slow(t);\n"
		+ "\tunsigned char *tlab = *(unsigned char**)(th + d->tlab_field);\n"
		+ "\tif( !tlab ) return hl_jit_alloc_slow(t);\n"
		+ "\tunsigned char **slot = (unsigned char**)(tlab + d->slot_offset);\n"
		+ "\tunsigned char *p = slot[0];\n"
		+ "\tif( !p || (uintptr_t)(p + d->block) > (uintptr_t)slot[1] ) return hl_jit_alloc_slow(t);\n"
		+ "\tslot[0] = p + d->block;\n"
		+ "\tfor(int o=HL_WSIZE;o<d->block;o+=HL_WSIZE) *(void**)(p + o) = NULL;\n"
		+ "\t*(hl_type**)p = d->type;\n"
		+ "\treturn p;\n"
		+ "#else\n"
		+ "\treturn hl_alloc_obj(t);\n"
		+ "#endif\n"
		+ "}\n\n";

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

	/** The C calling shape of a value of type `type`, one letter of a trampoline's key; `hlc_main.c` spells it the same. */
	function shapeCode(type:Int):String
		return switch types.kind(type) {
			case Void: "v";
			case Bool: "b";
			case Ui8: "c";
			case Ui16: "s";
			case I32, EnumTag: "i";
			case I64, Guid: "l";
			case F32: "f";
			case F64: "d";
			default: "p";
		};

	static function shapeType(code:String):String
		return switch code {
			case "v": "void";
			case "b": "bool";
			case "c": "unsigned char";
			case "s": "unsigned short";
			case "i": "int";
			case "l": "int64";
			case "f": "float";
			case "d": "double";
			default: "void*";
		};

	/**
	 * The trampolines the runtime calls compiled functions through, and wraps closures in, which the JIT would make
	 * (`hl_setup.static_call`, `get_wrapper`): one pair per C calling shape of the program's function types, and of each with
	 * its first argument bound, keyed by the result's shape and the arguments' (`hlc_signatures`, in key order).
	 */
	function trampolines(buffer:StringBuf):Void {
		var keys:Map<String, Bool> = [];
		for (index in 0...code.types.length)
			switch types.kind(index) {
				case Fun, Method:
					var signature = types.signature(index),
						shapes = [for (argument in signature.arguments) shapeCode(argument)];
					keys.set(shapeCode(signature.result) + shapes.join(""), true);
					if (shapes.length > 0)
						keys.set(shapeCode(signature.result) + shapes.slice(1).join(""), true);
				default:
			}
		var sorted = [for (key in keys.keys()) key];
		sorted.sort(Reflect.compare);
		for (key in sorted) {
			var result = key.charAt(0), arguments = [for (index in 1...key.length) key.charAt(index)];
			var parameters = [for (argument in arguments) shapeType(argument)];
			var values = [
				for (index in 0...arguments.length)
					arguments[index] == "p" ? 'a[$index]' : arguments[index] == "b" || arguments[index] == "c"
					|| arguments[index] == "s"
					? '(${shapeType(arguments[index])})*(int*)a[$index]' : '*(${shapeType(arguments[index])}*)a[$index]'
			];
			var call =
				'((${shapeType(result)} (*)(${parameters.length == 0 ? "void" : parameters.join(",")}))f)(${values.join(",")})';
			buffer.add('static void *hlc_call_$key( void *f, void **a, vdynamic *out ) {\n\t');
			buffer.add(switch result {
				case "v": '$call;\n\treturn NULL;\n';
				case "b", "c", "s", "i": 'out->v.i = (int)$call;\n\treturn &out->v.i;\n';
				case "l": 'out->v.i64 = $call;\n\treturn &out->v.i64;\n';
				case "f": 'out->v.f = $call;\n\treturn &out->v.f;\n';
				case "d": 'out->v.d = $call;\n\treturn &out->v.d;\n';
				default: 'return $call;\n';
			});
			buffer.add("}\n");
			var declared = ["void *w"].concat([for (index in 0...arguments.length) '${parameters[index]} p$index']);
			var packed = [for (index in 0...arguments.length) arguments[index] == "p" ? 'p$index' : '&p$index'];
			buffer.add('static ${shapeType(result)} hlc_wrap_$key( ${declared.join(", ")} ) {\n');
			buffer.add('\tvoid *args[] = {${packed.concat(["NULL"]).join(",")}};\n\tvdynamic ret;\n');
			buffer.add(switch result {
				case "v": '\thl_wrapper_call(w,args,&ret);\n';
				case "b", "c", "s", "i": '\thl_wrapper_call(w,args,&ret);\n\treturn (${shapeType(result)})ret.v.i;\n';
				case "l": '\thl_wrapper_call(w,args,&ret);\n\treturn ret.v.i64;\n';
				case "f": '\thl_wrapper_call(w,args,&ret);\n\treturn ret.v.f;\n';
				case "d": '\thl_wrapper_call(w,args,&ret);\n\treturn ret.v.d;\n';
				default: '\treturn hl_wrapper_call(w,args,&ret);\n';
			});
			buffer.add("}\n");
		}
		buffer.add("const hlc_signature hlc_signatures[] = {\n");
		for (key in sorted)
			buffer.add('\t{"$key",hlc_call_$key,(void*)hlc_wrap_$key},\n');
		buffer.add('\t{NULL,NULL,NULL}};\nconst int hlc_signature_count = ${sorted.length};\n\n');
	}

	/**
	 * The module image: this module with every function body a stub, which the runtime decodes into its types, globals,
	 * natives and constants (`hl_code_read`, `hl_module_init`) before the slots are pointed at the C functions; the slot table;
	 * and the layouts the C code assumes, which the runtime checks against its own before running anything.
	 */
	function image():String {
		var stubbed = new HlCode();
		stubbed.ints = code.ints;
		stubbed.floats = code.floats;
		stubbed.strings = code.strings;
		stubbed.types = code.types;
		stubbed.globals = code.globals;
		stubbed.natives = code.natives;
		stubbed.constants = code.constants;
		stubbed.entryPoint = code.entryPoint;
		// The functions' names, which stack traces show as the JIT's do.
		stubbed.debugSections =
			[for (section in code.debugSections) if (section.kind == HlWriter.FUNCTION_IDENTITIES) section];
		stubbed.functions = [for (fn in code.functions) {
			var signature = types.signature(fn.type);
			new HlFunction(fn.type, fn.functionIndex, signature.arguments.concat([signature.result]),
				[compiler.hl.HlFunction.HlInstruction.Return(signature.arguments.length)]);
		}];
		var bytes = HlWriter.encode(stubbed).flatten();
		var buffer = new StringBuf();
		buffer.add('#include "hlc.h"\n\n');
		buffer.add('const int hlc_image_size = ${bytes.length};\n');
		buffer.add("const unsigned char hlc_image[] = {");
		for (index in 0...bytes.length) {
			if (index % 32 == 0)
				buffer.add("\n");
			buffer.add(bytes.get(index));
			buffer.add(",");
		}
		buffer.add("0};\n\n");
		buffer.add('const int hlc_slot_count = ${slotTypes.length};\n');
		buffer.add('const int hlc_entry = ${code.entryPoint};\n');
		buffer.add("void *hlc_functions[] = {");
		for (slot in 0...slotTypes.length)
			buffer.add((slot % 4 == 0 ? "\n\t" : " ")
				+ (slotTypes[slot] >= 0 && !native[slot] ? '(void*)${cNames[slot]},' : "NULL,"));
		buffer.add("\n\tNULL};\n\n");
		trampolines(buffer);
		buffer.add('const int hlc_alloc_count = ${allocationTypes.length};\n');
		buffer.add('const int hlc_alloc_types[] = {${allocationTypes.concat([-1]).join(",")}};\n');
		buffer.add('hl_jit_alloc_data hlc_alloc_data[${allocationTypes.length + 1}];\n\n');
		// The C compiler's line table keeps a `#line` path relative to its working directory when the path is under it, so the
		// stack traces read the paths as written from here (`hlc_stack.c`).
		var paths = [for (path in sourcePaths.keys()) path];
		paths.sort(Reflect.compare);
		buffer.add('const int hlc_source_path_count = ${paths.length};\n');
		buffer.add("const char *const hlc_source_paths[] = {");
		for (path in paths)
			buffer.add('\n\t${quote(path)},');
		buffer.add("\n\tNULL};\n\n");
		buffer.add('const int hlc_global_count = ${globalOffsets.length};\n');
		buffer.add('const int hlc_global_offsets[] = {${globalOffsets.concat([-1]).join(",")}};\n\n');
		buffer.add("/* Object layouts: type, field count, then field index and offset pairs; -1 ends the list. */\n");
		buffer.add("const int hlc_object_layouts[] = {\n");
		for (index in 0...code.types.length)
			if (types.isObject(index)) {
				var fields = [for (field in types.fields(index)) if (!types.isVoid(field.type)) field];
				buffer.add('\t$index,${fields.length},');
				for (field in fields)
					buffer.add('${field.index},(int)offsetof(${types.structName(index)},f${field.index}),');
				buffer.add("\n");
			}
		buffer.add("\t-1};\n");
		return buffer.toString();
	}
}
